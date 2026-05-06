package jsonparse

import "bytes"

func SkipWS(p []byte) []byte {
	i := 0
	for i < len(p) && (p[i] == ' ' || p[i] == '\n' || p[i] == '\r' || p[i] == '\t') {
		i++
	}
	return p[i:]
}

func FindChar(p []byte, ch byte) int {
	for i := range p {
		if p[i] == ch {
			return i
		}
	}
	return -1
}

func FindKeyRange(data []byte, key string) ([]byte, bool) {
	pat := []byte("\"" + key + "\"")
	i := 0
	for i < len(data) {
		idx := bytes.Index(data[i:], pat)
		if idx == -1 {
			return nil, false
		}
		start := data[i+idx:]
		if len(start) >= len(pat) {
			return start, true
		}
		i += idx + 1
	}
	return nil, false
}

func MatchingBrace(open []byte) (int, bool) {
	if len(open) == 0 || open[0] != '{' {
		return 0, false
	}
	depth := 0
	inStr := false
	esc := false
	for i := 0; i < len(open); i++ {
		c := open[i]
		if inStr {
			if esc {
				esc = false
			} else if c == '\\' {
				esc = true
			} else if c == '"' {
				inStr = false
			}
			continue
		}
		if c == '"' {
			inStr = true
		} else if c == '{' {
			depth++
		} else if c == '}' {
			depth--
			if depth == 0 {
				return i + 1, true
			}
		}
	}
	return 0, false
}

func ObjectRange(data []byte, key string) ([]byte, bool) {
	k, ok := FindKeyRange(data, key)
	if !ok {
		return nil, false
	}
	colon := FindChar(k, ':')
	if colon == -1 {
		return nil, false
	}
	p := SkipWS(k[colon+1:])
	if len(p) == 0 || p[0] != '{' {
		return nil, false
	}
	closeIdx, ok := MatchingBrace(p)
	if !ok {
		return nil, false
	}
	return p[:closeIdx], true
}

func isNumberByte(c byte) bool {
	return (c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.'
}

func ParseFloat32(b []byte) (float32, bool) {
	if len(b) == 0 {
		return 0, false
	}
	i := 0
	sign := float32(1)
	if b[i] == '-' {
		sign = -1
		i++
		if i >= len(b) {
			return 0, false
		}
	}
	val := float32(0)
	hasDigits := false
	for i < len(b) && b[i] >= '0' && b[i] <= '9' {
		val = val*10 + float32(b[i]-'0')
		i++
		hasDigits = true
	}
	if i < len(b) && b[i] == '.' {
		i++
		frac := float32(0)
		div := float32(1)
		for i < len(b) && b[i] >= '0' && b[i] <= '9' {
			frac = frac*10 + float32(b[i]-'0')
			div *= 10
			i++
			hasDigits = true
		}
		val += frac / div
	}
	if !hasDigits {
		return 0, false
	}
	return sign * val, true
}

func JSONNumber(data []byte, key string) (float32, bool) {
	k, ok := FindKeyRange(data, key)
	if !ok {
		return 0, false
	}
	colon := FindChar(k, ':')
	if colon == -1 {
		return 0, false
	}
	p := SkipWS(k[colon+1:])
	if len(p) == 0 {
		return 0, false
	}
	end := 0
	for end < len(p) && isNumberByte(p[end]) {
		end++
	}
	if end == 0 {
		return 0, false
	}
	return ParseFloat32(p[:end])
}

func JSONBool(data []byte, key string) (int, bool) {
	k, ok := FindKeyRange(data, key)
	if !ok {
		return 0, false
	}
	colon := FindChar(k, ':')
	if colon == -1 {
		return 0, false
	}
	p := SkipWS(k[colon+1:])
	if len(p) >= 4 && string(p[:4]) == "true" {
		return 1, true
	}
	if len(p) >= 5 && string(p[:5]) == "false" {
		return 0, true
	}
	return 0, false
}

func JSONString(data []byte, key string, out []byte) ([]byte, bool) {
	k, ok := FindKeyRange(data, key)
	if !ok {
		return nil, false
	}
	colon := FindChar(k, ':')
	if colon == -1 {
		return nil, false
	}
	p := SkipWS(k[colon+1:])
	if len(p) == 0 || p[0] != '"' {
		return nil, false
	}
	p = p[1:]
	n := 0
	for n < len(p) && p[n] != '"' {
		if n < len(out) {
			out[n] = p[n]
		}
		n++
	}
	if n > len(out) {
		n = len(out)
	}
	return out[:n], n < len(p) && p[n] == '"'
}

func ArrayContainsString(data []byte, key string, needle []byte) bool {
	k, ok := FindKeyRange(data, key)
	if !ok {
		return false
	}
	colon := FindChar(k, ':')
	if colon == -1 {
		return false
	}
	lb := FindChar(k[colon:], '[')
	if lb == -1 {
		return false
	}
	p := k[colon+lb+1:]
	for {
		p = SkipWS(p)
		if len(p) == 0 || p[0] == ']' {
			break
		}
		if p[0] == '"' {
			p = p[1:]
			s := 0
			for s < len(p) && p[s] != '"' {
				s++
			}
			if s == len(needle) {
				match := true
				for i := 0; i < s; i++ {
					if p[i] != needle[i] {
						match = false
						break
					}
				}
				if match {
					return true
				}
			}
			p = p[s:]
			if len(p) > 0 && p[0] == '"' {
				p = p[1:]
			}
		} else {
			for len(p) > 0 && p[0] != ',' && p[0] != ']' {
				p = p[1:]
			}
		}
		if len(p) > 0 && p[0] == ',' {
			p = p[1:]
		}
	}
	return false
}
