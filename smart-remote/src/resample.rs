//! Streaming mono s16le conversion; Rubato owns anti-aliasing and filter state.
use rubato::{
    Resampler, SincFixedIn, SincInterpolationParameters, SincInterpolationType, WindowFunction,
};
pub type PcmError = String;
pub struct PcmConverter {
    rate: u32,
    volume: f64,
    filter: Option<SincFixedIn<f64>>,
    input: Vec<f64>,
    partial: Option<u8>,
    input_count: u64,
    emitted: u64,
    block: usize,
}
impl PcmConverter {
    pub fn new(rate: u32, volume: f64) -> Result<Self, PcmError> {
        if rate == 0 || rate > 192_000 || !volume.is_finite() || !(0.0..=1.0).contains(&volume) {
            return Err("Unsupported PCM rate or volume".into());
        }
        let block = (rate as usize / 50).clamp(16, 3840);
        let filter = if rate == 16_000 {
            None
        } else {
            Some(
                SincFixedIn::new(
                    16_000.0 / f64::from(rate),
                    1.0,
                    SincInterpolationParameters {
                        sinc_len: 128,
                        f_cutoff: 0.95,
                        interpolation: SincInterpolationType::Linear,
                        oversampling_factor: 128,
                        window: WindowFunction::BlackmanHarris2,
                    },
                    block,
                    1,
                )
                .map_err(|e| e.to_string())?,
            )
        };
        Ok(Self {
            rate,
            volume,
            filter,
            input: Vec::new(),
            partial: None,
            input_count: 0,
            emitted: 0,
            block,
        })
    }
    pub fn push(&mut self, bytes: &[u8], end: bool) -> Result<Vec<u8>, PcmError> {
        let mut aligned = Vec::with_capacity(bytes.len() + 1);
        if let Some(byte) = self.partial.take() {
            aligned.push(byte);
        }
        aligned.extend_from_slice(bytes);
        if aligned.len() % 2 != 0 {
            self.partial = aligned.pop();
        }
        self.input_count += (aligned.len() / 2) as u64;
        self.input.extend(
            aligned
                .chunks_exact(2)
                .map(|s| f64::from(i16::from_le_bytes([s[0], s[1]]))),
        );
        let mut result = Vec::new();
        if self.filter.is_none() {
            let samples = std::mem::take(&mut self.input);
            self.encode(&samples, &mut result, u64::MAX);
        } else {
            while self.input.len() >= self.block {
                let samples: Vec<_> = self.input.drain(..self.block).collect();
                let output = self
                    .filter
                    .as_mut()
                    .ok_or_else(|| "Missing PCM filter".to_owned())?
                    .process(&[samples], None)
                    .map_err(|e| e.to_string())?;
                self.encode(&output[0], &mut result, u64::MAX);
            }
            if end {
                let expected = self.input_count * 16_000 / u64::from(self.rate);
                let remaining = [std::mem::take(&mut self.input)];
                let output = self
                    .filter
                    .as_mut()
                    .ok_or_else(|| "Missing PCM filter".to_owned())?
                    .process_partial(
                        if remaining[0].is_empty() {
                            None
                        } else {
                            Some(&remaining)
                        },
                        None,
                    )
                    .map_err(|e| e.to_string())?;
                self.encode(&output[0], &mut result, expected);
                // Flush the library's delayed filter tail, trimming padding to the exact duration.
                while self.emitted < expected {
                    let output = self
                        .filter
                        .as_mut()
                        .ok_or_else(|| "Missing PCM filter".to_owned())?
                        .process_partial::<Vec<f64>>(None, None)
                        .map_err(|e| e.to_string())?;
                    self.encode(&output[0], &mut result, expected);
                }
            }
        }
        if end && self.partial.is_some() {
            return Err("PCM ended with an incomplete sample".into());
        }
        Ok(result)
    }
    fn encode(&mut self, samples: &[f64], output: &mut Vec<u8>, limit: u64) {
        for sample in samples {
            if self.emitted >= limit {
                break;
            }
            output.extend_from_slice(
                &((sample * self.volume).round().clamp(-32768.0, 32767.0) as i16).to_le_bytes(),
            );
            self.emitted += 1;
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn split_chunks_preserve_duration_waveform_and_identity() {
        let source: Vec<u8> = (0..2400)
            .flat_map(|n| {
                ((f64::sin(n as f64 * std::f64::consts::TAU * 1000.0 / 24000.0) * 12000.0) as i16)
                    .to_le_bytes()
            })
            .collect();
        let mut whole = PcmConverter::new(24000, 1.0).unwrap();
        let expected = whole.push(&source, true).unwrap();
        let mut split = PcmConverter::new(24000, 1.0).unwrap();
        let mut actual = Vec::new();
        for chunk in source.chunks(333) {
            actual.extend(split.push(chunk, false).unwrap());
        }
        actual.extend(split.push(&[], true).unwrap());
        assert_eq!(actual, expected);
        assert_eq!(actual.len(), 3200);
        // Independent 1 kHz oracle allows the sinc filter's fractional-sample phase.
        for (n, sample) in actual.chunks_exact(2).enumerate().skip(100).take(1300) {
            let got = f64::from(i16::from_le_bytes([sample[0], sample[1]]));
            let want = (n as f64 * std::f64::consts::TAU * 1000.0 / 16000.0).sin() * 12000.0;
            assert!((got - want).abs() < 2000.0, "sample{n}: {got} vs{want}");
        }
        let mut identity = PcmConverter::new(16000, 1.0).unwrap();
        assert_eq!(identity.push(&source, true).unwrap(), source);
    }
}
