//! Opt-in resolver. Explicit selections and reported identity constrain one installed catalog.
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

use serde::{Deserialize, Serialize};

use crate::client::SlicingIdentity;
use crate::error::{Error, Result};
use crate::slicer::{identifier, SlicerConfig};
use crate::slicer_catalog::Catalog;

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Selections {
    pub executable: Option<PathBuf>,
    pub vendor_ini: Option<PathBuf>,
    pub vendor_id: Option<String>,
    pub model_id: Option<String>,
    pub variant: Option<String>,
    pub tool_count: Option<u8>,
    pub printer_profile: Option<String>,
    pub print_profile: Option<String>,
    pub material_profile: Option<String>,
}
#[derive(Default, Serialize)]
pub struct Candidates {
    pub models: Vec<ModelChoice>,
    pub variants: Vec<String>,
    pub tool_counts: Vec<u8>,
    pub printer_profiles: Vec<String>,
    pub print_profiles: Vec<String>,
    pub material_profiles: Vec<String>,
}
#[derive(Serialize)]
pub struct ModelChoice {
    id: String,
    name: String,
}
#[derive(Serialize)]
pub struct Resolution {
    pub mapping: Option<SlicerConfig>,
    pub identity: SlicingIdentity,
    pub model_source: &'static str,
    pub needed_fields: Vec<&'static str>,
    pub candidates: Candidates,
    pub reason: &'static str,
    pub run_directory: Option<PathBuf>,
    pub executable_sha256: Option<String>,
    pub vendor_sha256: Option<String>,
    pub version: Option<String>,
}
impl Resolution {
    fn need(&mut self, field: &'static str, reason: &'static str) {
        self.needed_fields.push(field);
        self.reason = reason;
    }
}
fn unique<T: Ord>(values: impl Iterator<Item = T>) -> Vec<T> {
    values.collect::<BTreeSet<_>>().into_iter().collect()
}
fn choose<'a>(names: &'a [String], selected: Option<&String>) -> Option<&'a String> {
    match selected {
        Some(selected) => names.iter().find(|name| *name == selected),
        None if names.len() == 1 => names.first(),
        None => None,
    }
}

pub fn resolve(
    selection: Selections,
    identity: SlicingIdentity,
    root: &Path,
) -> Result<Resolution> {
    let started = Instant::now();
    let mut reply = Resolution {
        mapping: None,
        identity,
        model_source: "unverified",
        needed_fields: Vec::new(),
        candidates: Candidates::default(),
        reason: "Explicit catalog selections are required",
        run_directory: None,
        executable_sha256: None,
        vendor_sha256: None,
        version: None,
    };
    let app = Path::new("/Applications/PrusaSlicer.app/Contents");
    let executable = selection.executable.clone().or_else(|| {
        let path = app.join("MacOS/PrusaSlicer");
        (cfg!(target_os = "macos") && path.is_file()).then_some(path)
    });
    let vendor_ini = selection.vendor_ini.clone().or_else(|| {
        let path = app.join("Resources/profiles/PrusaResearch.ini");
        (cfg!(target_os = "macos") && path.is_file()).then_some(path)
    });
    if executable.is_none() {
        reply.need(
            "executable",
            "Installed slicer not found; select local paths or use a manual slicing mapping",
        );
    }
    if vendor_ini.is_none() {
        reply.need("vendor_ini", "Installed vendor catalog not found; select local paths or use a manual slicing mapping");
    }
    let (Some(executable), Some(vendor_ini)) = (executable, vendor_ini) else {
        return Ok(reply);
    };
    let vendor_id = selection
        .vendor_id
        .clone()
        .or_else(|| vendor_ini.file_stem()?.to_str().map(str::to_owned))
        .ok_or(Error::Invalid("Select the installed vendor identifier"))?;
    let catalog = Catalog::prepare(&executable, &vendor_ini, &vendor_id, "", root, started)?;
    let settings = installed_settings(
        &catalog
            .directory
            .join("vendor")
            .join(format!("{vendor_id}.ini")),
        &vendor_id,
    )?;
    fs::write(catalog.directory.join("PrusaSlicer.ini"), settings)
        .map_err(|_| Error::Io("Cannot enable installed slicer models"))?;
    reply.run_directory = Some(catalog.directory.clone());
    reply.executable_sha256 = Some(catalog.executable_sha256.clone());
    reply.vendor_sha256 = Some(catalog.vendor_sha256.clone());
    reply.mapping = resolve_catalog(&catalog, &selection, &mut reply)?;
    if reply.mapping.is_some() {
        reply.version = Some(catalog.version()?);
        reply.reason = "Resolved uniquely against the installed catalog";
    }
    catalog.unchanged()?;
    Ok(reply)
}

/// Enable every declared variant, rather than querying a configured one-model subset.
fn installed_settings(path: &Path, vendor_id: &str) -> Result<String> {
    if !identifier(vendor_id) {
        return Err(Error::Invalid("Use a simple slicer vendor identifier"));
    }
    let path = crate::slicer::local_file(path)?;
    if fs::metadata(&path)
        .map_err(|_| Error::Io("Cannot inspect installed vendor catalog"))?
        .len()
        > 4 * 1024 * 1024
    {
        return Err(Error::Invalid("Installed vendor catalog exceeds4MiB"));
    }
    let text =
        fs::read_to_string(path).map_err(|_| Error::Io("Cannot read installed vendor catalog"))?;
    let mut enabled = BTreeMap::<String, Vec<String>>::new();
    let mut model = None;
    for line in text.lines().map(str::trim) {
        if line.starts_with('[') {
            model = line
                .strip_prefix("[printer_model:")
                .and_then(|line| line.strip_suffix(']'))
                .map(str::to_owned);
            if model.as_ref().is_some_and(|id| !identifier(id)) {
                return Err(Error::Protocol("Invalid installed model identifier"));
            }
        } else if let (Some(model), Some(("variants", variants))) = (
            model.as_ref(),
            line.split_once('=')
                .map(|(key, value)| (key.trim(), value.trim())),
        ) {
            let variants: Vec<_> = variants
                .split(';')
                .map(str::trim)
                .map(str::to_owned)
                .collect();
            if variants.iter().any(|variant| !identifier(variant)) {
                return Err(Error::Protocol("Invalid installed model variant"));
            }
            if enabled.insert(model.clone(), variants).is_some() {
                return Err(Error::Protocol("Duplicate installed model variants"));
            }
        }
    }
    if enabled.is_empty() {
        return Err(Error::Protocol(
            "Installed vendor catalog declares no model variants",
        ));
    }
    Ok(format!(
        "[vendor:{vendor_id}]\n{}",
        enabled
            .into_iter()
            .map(|(model, variants)| format!("model:{model} = {}\n", variants.join("; ")))
            .collect::<String>()
    ))
}

fn resolve_catalog(
    catalog: &Catalog,
    selection: &Selections,
    reply: &mut Resolution,
) -> Result<Option<SlicerConfig>> {
    let catalog_models = catalog.models()?;
    let models: Vec<_> = catalog_models
        .printer_models
        .iter()
        .filter(|model| model.vendor_id == catalog.vendor_id)
        .collect();
    reply.candidates.models = models
        .iter()
        .map(|model| ModelChoice {
            id: model.id.clone(),
            name: model.name.clone(),
        })
        .collect();
    reply.candidates.models.sort_by(|a, b| a.id.cmp(&b.id));
    let reported: Vec<_> = models
        .iter()
        .filter(|model| {
            reply
                .identity
                .version_printer
                .as_ref()
                .is_some_and(|label| *label == model.id || *label == model.name)
        })
        .collect();
    let model = if let Some(id) = &selection.model_id {
        reply.model_source = "user_selection";
        if !reported.is_empty() && !reported.iter().any(|model| &model.id == id) {
            reply.need("model_id", "Explicit model contradicts recognized reported identity; configuration was preserved");
            return Ok(None);
        }
        models
            .iter()
            .filter(|model| &model.id == id)
            .collect::<Vec<_>>()
    } else {
        reply.model_source = "reported_catalog_identity";
        reported
    };
    if model.len() != 1 {
        reply.model_source = "unverified";
        reply.need(
            "model_id",
            "Select an exact catalog model ID; reported identity is unknown or ambiguous",
        );
        return Ok(None);
    }
    let model = model[0];
    let identity = &reply.identity;
    if matches!((identity.version_nozzle_diameter, identity.info_nozzle_diameter), (Some(a), Some(b)) if (a-b).abs() > 0.000001)
    {
        reply.need(
            "printer_identity",
            "Reported nozzle diameters conflict; resolve printer identity before configuring",
        );
        return Ok(None);
    }
    let nozzle = identity
        .info_nozzle_diameter
        .or(identity.version_nozzle_diameter);
    let variants: Vec<_> = model
        .variants
        .iter()
        .filter(|variant| {
            let name = variant.name();
            nozzle.is_none_or(|nozzle| {
                name.strip_prefix("HF")
                    .unwrap_or(&name)
                    .parse::<f64>()
                    .is_ok_and(|diameter| (nozzle - diameter).abs() < 0.000001)
            })
        })
        .collect();
    reply.candidates.variants = unique(variants.iter().map(|variant| variant.name()));
    let Some(variant_name) = choose(&reply.candidates.variants, selection.variant.as_ref()) else {
        reply.need(
            "variant",
            "Select an exact nozzle/HF variant consistent with reported diameter",
        );
        return Ok(None);
    };
    let variant_name = variant_name.clone();
    let profiles: Vec<_> = variants
        .iter()
        .filter(|variant| variant.name() == variant_name)
        .flat_map(|variant| &variant.printer_profiles)
        .collect();
    reply.candidates.tool_counts = unique(profiles.iter().map(|profile| profile.extruders_cnt));
    let profiles: Vec<_> = profiles
        .into_iter()
        .filter(|profile| {
            selection
                .tool_count
                .is_none_or(|count| count == profile.extruders_cnt)
        })
        .collect();
    reply.candidates.printer_profiles = unique(profiles.iter().map(|profile| profile.name.clone()));
    let Some(printer_name) = choose(
        &reply.candidates.printer_profiles,
        selection.printer_profile.as_ref(),
    ) else {
        reply.need(
            "printer_profile",
            "Select a unique printer profile and tool count",
        );
        return Ok(None);
    };
    let matching: Vec<_> = profiles
        .iter()
        .filter(|profile| &profile.name == printer_name)
        .collect();
    if matching.len() != 1 || !(1..=16).contains(&matching[0].extruders_cnt) {
        reply.need(
            "tool_count",
            "Printer profile and tool count must resolve uniquely",
        );
        return Ok(None);
    }
    let printer = matching[0];
    let profiles = catalog.profiles(&printer.name)?;
    reply.candidates.print_profiles = unique(
        profiles
            .print_profiles
            .iter()
            .map(|profile| profile.name.clone()),
    );
    let Some(print) = choose(
        &reply.candidates.print_profiles,
        selection.print_profile.as_ref(),
    ) else {
        reply.need(
            "print_profile",
            "Select a print profile; no default is guessed",
        );
        return Ok(None);
    };
    reply.candidates.material_profiles = unique(
        profiles
            .print_profiles
            .iter()
            .filter(|profile| &profile.name == print)
            .flat_map(|profile| profile.filament_profiles.iter().cloned()),
    );
    let Some(material) = choose(
        &reply.candidates.material_profiles,
        selection.material_profile.as_ref(),
    ) else {
        reply.need(
            "material_profile",
            "Select a compatible material profile; loaded filament is not inferred",
        );
        return Ok(None);
    };
    if !profiles.compatible(print, material) {
        return Err(Error::Invalid(
            "Print/material profiles are not compatible with this printer catalog",
        ));
    }
    let mapping = SlicerConfig {
        executable: catalog.executable.clone(),
        vendor_ini: catalog.vendor_ini.clone(),
        vendor_id: catalog.vendor_id.clone(),
        model_id: model.id.clone(),
        variant: variant_name,
        tool_count: printer.extruders_cnt,
        printer_profile: printer.name.clone(),
        print_profile: print.clone(),
        material_profile: material.clone(),
    };
    mapping.validate()?;
    catalog_models.printer(&mapping)?.bed.center()?;
    Ok(Some(mapping))
}
