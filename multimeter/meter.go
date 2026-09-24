package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"log"
	"sync"
	"time"

	"tinygo.org/x/bluetooth"
)

// Meter owns the BLE link to one OWON B41T+: it scans for the meter, keeps
// the connection alive, decodes every notification into the ring buffer and
// hands each Reading to onReading. All methods are safe from any goroutine.
type Meter struct {
	adapter   *bluetooth.Adapter
	onReading func(Reading)
	onState   func()

	mu        sync.Mutex
	connected bool
	name      string
	address   string
	info      map[string]string
	control   bluetooth.DeviceCharacteristic
	device    bluetooth.Device
	ring      []Reading
	ringNext  int
	ringCount int
	lastErr   string
}

const ringSize = 600 // ~3-4 minutes at the meter's 2-3 Hz

var (
	uuidService  = bluetooth.New16BitUUID(0xFFF0)
	uuidControl  = bluetooth.New16BitUUID(0xFFF3)
	uuidNotify   = bluetooth.New16BitUUID(0xFFF4)
	uuidDevInfo  = bluetooth.New16BitUUID(0x180A)
	devInfoChars = map[uint16]string{
		0x2A24: "model", 0x2A25: "serial", 0x2A26: "firmware", 0x2A29: "manufacturer",
	}
)

// Button codes the meter accepts on 0xFFF3 (from jtcash/OwonB41T). A short
// press is 0x0100|code, a long press is the bare code, written little-endian.
var buttons = map[string]uint16{
	"select": 1, "range": 2, "hold": 3, "rel": 4, "hz": 5, "maxmin": 6,
}

func NewMeter(onReading func(Reading), onState func()) *Meter {
	return &Meter{
		adapter:   bluetooth.DefaultAdapter,
		onReading: onReading,
		onState:   onState,
		ring:      make([]Reading, ringSize),
		info:      map[string]string{},
	}
}

// Run scans, connects and reconnects forever. Call in its own goroutine.
func (m *Meter) Run() {
	if err := m.adapter.Enable(); err != nil {
		m.setError("bluetooth adapter unavailable: " + err.Error())
		return
	}
	disconnected := make(chan struct{}, 1)
	m.adapter.SetConnectHandler(func(d bluetooth.Device, connected bool) {
		if !connected {
			select {
			case disconnected <- struct{}{}:
			default:
			}
		}
	})
	for {
		if err := m.connectOnce(); err != nil {
			m.setError(err.Error())
			time.Sleep(3 * time.Second)
			continue
		}
		<-disconnected
		m.mu.Lock()
		m.connected = false
		m.lastErr = "meter disconnected"
		m.mu.Unlock()
		m.onState()
		time.Sleep(time.Second)
	}
}

// connectOnce finds the meter, subscribes to readings and reads the device
// information service. Returns once the link is up.
func (m *Meter) connectOnce() error {
	// Scan blocks until StopScan, so it runs on its own goroutine and the
	// timeout below is what ends an empty scan (CoreBluetooth silently drops
	// a scan issued before the user answers the Bluetooth permission dialog).
	found := make(chan bluetooth.ScanResult, 1)
	scanErr := make(chan error, 1)
	go func() {
		scanErr <- m.adapter.Scan(func(a *bluetooth.Adapter, r bluetooth.ScanResult) {
			if r.HasServiceUUID(uuidService) || r.LocalName() == "BDM" {
				a.StopScan()
				select {
				case found <- r:
				default:
				}
			}
		})
	}()
	var res bluetooth.ScanResult
	select {
	case res = <-found:
	case err := <-scanErr:
		return fmt.Errorf("scan: %w", err)
	case <-time.After(20 * time.Second):
		m.adapter.StopScan()
		return errors.New("no OWON meter found; turn it on and enable Bluetooth on it")
	}
	dev, err := m.adapter.Connect(res.Address, bluetooth.ConnectionParams{})
	if err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	svcs, err := dev.DiscoverServices([]bluetooth.UUID{uuidService, uuidDevInfo})
	if err != nil {
		dev.Disconnect()
		return fmt.Errorf("discover services: %w", err)
	}
	info := map[string]string{}
	var control, notify bluetooth.DeviceCharacteristic
	var haveNotify bool
	for _, s := range svcs {
		switch s.UUID() {
		case uuidService:
			chars, err := s.DiscoverCharacteristics([]bluetooth.UUID{uuidControl, uuidNotify})
			if err != nil {
				dev.Disconnect()
				return fmt.Errorf("discover characteristics: %w", err)
			}
			for _, c := range chars {
				switch c.UUID() {
				case uuidControl:
					control = c
				case uuidNotify:
					notify, haveNotify = c, true
				}
			}
		case uuidDevInfo:
			chars, _ := s.DiscoverCharacteristics(nil)
			buf := make([]byte, 64)
			for _, c := range chars {
				key, ok := devInfoChars[c.UUID().Get16Bit()]
				if !ok {
					continue
				}
				// The B41T+ ships TI's stock device-information strings
				// ("Model Number", "Firmware Revision", ...); those are noise.
				if n, err := c.Read(buf); err == nil && n > 0 && !isStockDevInfo(string(buf[:n])) {
					info[key] = string(buf[:n])
				}
			}
		}
	}
	if !haveNotify {
		dev.Disconnect()
		return errors.New("meter has no reading characteristic (0xFFF4)")
	}
	if err := notify.EnableNotifications(m.onPacket); err != nil {
		dev.Disconnect()
		return fmt.Errorf("subscribe: %w", err)
	}
	m.mu.Lock()
	m.connected = true
	m.lastErr = ""
	m.name = res.LocalName()
	m.address = res.Address.String()
	m.info = info
	m.control = control
	m.device = dev
	m.mu.Unlock()
	log.Printf("connected to %s (%s) %v", m.name, m.address, info)
	m.onState()
	return nil
}

func isStockDevInfo(v string) bool {
	switch v {
	case "Model Number", "Serial Number", "Firmware Revision", "Manufacturer Name":
		return true
	}
	return false
}

func (m *Meter) onPacket(pkt []byte) {
	r, err := Decode(pkt, time.Now())
	if err != nil {
		log.Printf("bad packet %x: %v", pkt, err)
		return
	}
	m.mu.Lock()
	m.ring[m.ringNext] = r
	m.ringNext = (m.ringNext + 1) % ringSize
	if m.ringCount < ringSize {
		m.ringCount++
	}
	m.mu.Unlock()
	m.onReading(r)
}

func (m *Meter) setError(msg string) {
	m.mu.Lock()
	m.lastErr = msg
	m.mu.Unlock()
	log.Print(msg)
	m.onState()
}

// Status is the snapshot the status tool and plugin_state both report.
func (m *Meter) Status() map[string]interface{} {
	m.mu.Lock()
	defer m.mu.Unlock()
	s := map[string]interface{}{
		"connected": m.connected,
		"name":      m.name,
		"address":   m.address,
		"info":      m.info,
		"error":     m.lastErr,
	}
	if m.ringCount > 0 {
		last := m.ring[(m.ringNext-1+ringSize)%ringSize]
		s["last"] = last
	}
	return s
}

// Recent returns up to n readings, oldest first.
func (m *Meter) Recent(n int) []Reading {
	m.mu.Lock()
	defer m.mu.Unlock()
	if n <= 0 || n > m.ringCount {
		n = m.ringCount
	}
	out := make([]Reading, 0, n)
	start := (m.ringNext - n + ringSize) % ringSize
	for i := 0; i < n; i++ {
		out = append(out, m.ring[(start+i)%ringSize])
	}
	return out
}

// Press sends one front-panel button to the meter.
func (m *Meter) Press(button string, long bool) error {
	code, ok := buttons[button]
	if !ok {
		return fmt.Errorf("unknown button %q", button)
	}
	m.mu.Lock()
	connected, control := m.connected, m.control
	m.mu.Unlock()
	if !connected {
		return errors.New("meter not connected")
	}
	if !long {
		code |= 0x0100
	}
	var word [2]byte
	binary.LittleEndian.PutUint16(word[:], code)
	_, err := control.Write(word[:])
	return err
}
