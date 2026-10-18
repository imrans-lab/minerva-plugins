package main

import (
	"bufio"
	"encoding/json"
	"io"
)

type wireDecoder struct{ reader *bufio.Reader }

func newWireDecoder(input io.Reader) *wireDecoder {
	return &wireDecoder{reader: bufio.NewReader(input)}
}

// A JSON value can end before its NDJSON record. Drain the delimiter before
// replying so the synchronous pipe's writer can finish its complete record.
func (d *wireDecoder) Decode(value any) error {
	line, err := d.reader.ReadBytes('\n')
	if err != nil {
		return err
	}
	return json.Unmarshal(line, value)
}
