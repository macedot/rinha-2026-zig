package mccrisk

import (
	"fmt"
	"os"
	"strconv"
)

var defaults = []struct {
	code int
	risk float32
}{
	{5411, 0.15}, {5812, 0.30}, {5912, 0.20},
	{5944, 0.45}, {7801, 0.80}, {7802, 0.75},
	{7995, 0.85}, {4511, 0.35}, {5311, 0.25},
	{5999, 0.50},
}

type Table struct {
	entries map[int]float32
}

func Load(path string) *Table {
	t := &Table{entries: make(map[int]float32, 4096)}
	for _, d := range defaults {
		t.entries[d.code] = d.risk
	}
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "mcc_risk: usando tabela default; nao abriu %s\n", path)
		return t
	}
	p := data
	for {
		idx := findQuote(p)
		if idx == -1 {
			break
		}
		p = p[idx+1:]
		if len(p) < 5 {
			break
		}
		code := parse4Digit(p)
		if code < 0 || p[4] != '"' {
			p = p[4:]
			continue
		}
		colonIdx := findChar(p[5:], ':')
		if colonIdx == -1 {
			break
		}
		valStart := p[5+colonIdx+1:]
		j := 0
		for j < len(valStart) && (valStart[j] == ' ' || valStart[j] == '\t') {
			j++
		}
		end := j
		for end < len(valStart) && isNumOrDot(valStart[end]) {
			end++
		}
		if end > j {
			if v, err := strconv.ParseFloat(string(valStart[j:end]), 32); err == nil {
				t.entries[code] = float32(v)
			}
		}
		p = valStart
	}
	return t
}

func (t *Table) GetBytes(mcc []byte) float32 {
	if len(mcc) < 4 {
		return 0.50
	}
	code := 0
	for i := 0; i < 4; i++ {
		c := mcc[i]
		if c < '0' || c > '9' {
			return 0.50
		}
		code = code*10 + int(c-'0')
	}
	if r, ok := t.entries[code]; ok {
		return r
	}
	return 0.50
}

func findQuote(b []byte) int {
	for i := range b {
		if b[i] == '"' {
			return i
		}
	}
	return -1
}

func findChar(b []byte, ch byte) int {
	for i := range b {
		if b[i] == ch {
			return i
		}
	}
	return -1
}

func parse4Digit(b []byte) int {
	if len(b) < 4 {
		return -1
	}
	code := 0
	for i := 0; i < 4; i++ {
		c := b[i]
		if c < '0' || c > '9' {
			return -1
		}
		code = code*10 + int(c-'0')
	}
	return code
}

func isNumOrDot(c byte) bool {
	return (c >= '0' && c <= '9') || c == '.' || c == '-'
}
