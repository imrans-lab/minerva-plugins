// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"bufio"
	"context"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/google/gousb"
)

const firmwareVersion = 0x0210

var rates = map[int]byte{100000: 110, 200000: 120, 500000: 150, 1000000: 1}

type firmwareRecord struct {
	address uint16
	data    []byte
}

// Validate the entire image before stopping the FX2 CPU. Only RAM records
// below the CPU-control register are accepted; EEPROM is never written.
func parseFirmware(data string) ([]firmwareRecord, error) {
	var records []firmwareRecord
	s := bufio.NewScanner(strings.NewReader(data))
	ended := false
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" {
			continue
		}
		if ended || !strings.HasPrefix(line, ":") {
			return nil, fmt.Errorf("invalid firmware record")
		}
		b, e := hex.DecodeString(line[1:])
		if e != nil || len(b) < 5 {
			return nil, fmt.Errorf("invalid firmware hex")
		}
		var sum byte
		for _, v := range b {
			sum += v
		}
		if sum != 0 || int(b[0])+5 != len(b) {
			return nil, fmt.Errorf("firmware checksum/length mismatch")
		}
		addr := uint16(b[1])<<8 | uint16(b[2])
		switch b[3] {
		case 0:
			if int(addr)+int(b[0]) > 0x4000 {
				return nil, fmt.Errorf("firmware outside internal RAM")
			}
			records = append(records, firmwareRecord{addr, append([]byte(nil), b[4:len(b)-1]...)})
		case 1:
			if b[0] != 0 {
				return nil, fmt.Errorf("bad firmware EOF")
			}
			ended = true
		default:
			return nil, fmt.Errorf("unsupported firmware record %d", b[3])
		}
	}
	if e := s.Err(); e != nil {
		return nil, e
	}
	if !ended || len(records) == 0 {
		return nil, fmt.Errorf("incomplete firmware")
	}
	return records, nil
}

type Hardware struct {
	ctx         *gousb.Context
	dev         *gousb.Device
	intf        *gousb.Interface
	done        func()
	ep          *gousb.InEndpoint
	zero        [2]float64
	serial      string
	calibration string
}

func (h *Hardware) Close() {
	if h.intf != nil {
		h.intf.Close()
		h.intf = nil
	}
	if h.done != nil {
		h.done()
		h.done = nil
	}
	if h.dev != nil {
		h.dev.Close()
		h.dev = nil
	}
	if h.ctx != nil {
		h.ctx.Close()
		h.ctx = nil
	}
	h.ep = nil
}
func writeControl(d *gousb.Device, request byte, address uint16, data []byte) error {
	n, e := d.Control(0x40, request, address, 0, data)
	if e != nil {
		return e
	}
	if n != len(data) {
		return fmt.Errorf("short USB control write: %d/%d", n, len(data))
	}
	return nil
}
func (h *Hardware) command(request, value byte) error {
	return writeControl(h.dev, request, 0, []byte{value})
}
func (h *Hardware) Open() (err error) {
	defer func() {
		if err != nil {
			h.Close()
		}
	}()
	h.ctx = gousb.NewContext()
	h.dev, err = h.ctx.OpenDeviceWithVIDPID(0x04b5, 0x6022)
	if err != nil {
		return err
	}
	if h.dev == nil {
		h.dev, err = h.ctx.OpenDeviceWithVIDPID(0x04b4, 0x6022)
		if err != nil {
			return err
		}
		if h.dev == nil {
			return fmt.Errorf("Hantek 6022BE not found; connect its USB data cable")
		}
		exe, e := os.Executable()
		if e != nil {
			return e
		}
		data, e := os.ReadFile(filepath.Join(filepath.Dir(exe), "firmware", "dso6022be.hex"))
		if e != nil {
			return e
		}
		records, e := parseFirmware(string(data))
		if e != nil {
			return e
		}
		h.dev.ControlTimeout = time.Second
		if e = writeControl(h.dev, 0xa0, 0xe600, []byte{1}); e != nil {
			return fmt.Errorf("stop FX2 CPU: %w", e)
		}
		for _, r := range records {
			if e = writeControl(h.dev, 0xa0, r.address, r.data); e != nil {
				return fmt.Errorf("load firmware RAM: %w; unplug/replug scope", e)
			}
		}
		if e = writeControl(h.dev, 0xa0, 0xe600, []byte{0}); e != nil {
			return fmt.Errorf("start FX2 CPU: %w", e)
		}
		h.dev.Close()
		h.dev = nil
		for i := 0; i < 40; i++ {
			time.Sleep(100 * time.Millisecond)
			h.dev, err = h.ctx.OpenDeviceWithVIDPID(0x04b5, 0x6022)
			if h.dev != nil {
				break
			}
		}
		if h.dev == nil {
			return fmt.Errorf("firmware loaded but scope did not reappear: %v", err)
		}
	}
	if uint16(h.dev.Desc.Device) != firmwareVersion {
		return fmt.Errorf("unsupported scope firmware %s; unplug/replug to load bundled firmware", h.dev.Desc.Device)
	}
	h.dev.ControlTimeout = time.Second
	var config *gousb.Config
	config, err = h.dev.Config(1)
	if err != nil {
		return fmt.Errorf("set USB configuration: %w", err)
	}
	h.done = func() { config.Close() }
	h.intf, err = config.Interface(0, 0)
	if err != nil {
		return fmt.Errorf("claim USB interface (close other scope applications): %w", err)
	}
	h.ep, err = h.intf.InEndpoint(6)
	if err != nil {
		return err
	}
	h.serial, _ = h.dev.SerialNumber()
	if err = h.command(0xe3, 0); err != nil {
		return err
	}
	if err = h.command(0xe4, 2); err != nil {
		return err
	}
	h.zero = [2]float64{128, 128}
	h.calibration = "nominal (EEPROM offset unavailable)"
	cal := make([]byte, 32)
	n, e := h.dev.Control(0xc0, 0xa2, 8, 0, cal)
	if e == nil && n == 32 && cal[14] > 0 && cal[14] < 255 && cal[15] > 0 && cal[15] < 255 {
		h.zero = [2]float64{float64(cal[14]), float64(cal[15])}
		h.calibration = "factory EEPROM zero offset; nominal gain"
	}
	return nil
}
func (h *Hardware) Capture(rate, samples int) (raw []byte, err error) {
	code, ok := rates[rate]
	if !ok {
		return nil, fmt.Errorf("unsupported rate")
	}
	for _, cmd := range [][2]byte{{0xe0, 1}, {0xe1, 1}, {0xe2, code}} {
		if err = h.command(cmd[0], cmd[1]); err != nil {
			return nil, err
		}
	}
	if err = h.command(0xe3, 1); err != nil {
		return nil, err
	}
	defer func() {
		e := h.command(0xe3, 0)
		if err == nil && e != nil {
			err = e
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	// Discard the first 512 sample pairs after restarting the ADC/FIFO.
	// This settling interval is declared in capture metadata.
	raw = make([]byte, (samples+512)*2)
	n, err := h.ep.ReadContext(ctx, raw)
	if err != nil {
		return nil, fmt.Errorf("USB capture: %w (%d bytes)", err, n)
	}
	if n != len(raw) {
		return nil, fmt.Errorf("short USB capture: %d/%d bytes", n, len(raw))
	}
	return raw[1024:], nil
}
