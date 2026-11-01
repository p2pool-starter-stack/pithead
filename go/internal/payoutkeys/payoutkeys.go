package payoutkeys

import (
	"encoding/hex"
	"math/big"
)

type point struct {
	x, y, z, t *big.Int
}

var (
	p       = integer("7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed", 16)
	l       = integer("1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3ed", 16)
	d       = mod(new(big.Int).Mul(big.NewInt(-121665), inverse(big.NewInt(121666))))
	i       = integer("2b8324804fc1df0b2b4d00993dfbd7a72f431806ad2fe478c4ee1b274a0ea0b0", 16)
	inv     = integer("786c8905cfaffca216c27b91fe01d8409d2f16175a4172be99c8fdaa805d40ea", 16)
	sqrtExp = new(big.Int).Div(new(big.Int).Sub(p, big.NewInt(5)), big.NewInt(8))
)

func Derive(chain string, private string) (string, bool) {
	secret, ok := decodeHex(private)
	if !ok || len(secret) != 32 {
		return "", false
	}
	k := littleInteger(secret)
	if k.Sign() <= 0 || k.Cmp(l) >= 0 {
		return "", false
	}
	if chain != "monero" && chain != "tari" {
		return "", false
	}
	y := mod(new(big.Int).Mul(big.NewInt(4), inverse(big.NewInt(5))))
	y2 := mod(new(big.Int).Mul(y, y))
	x := sqrtRatio(new(big.Int).Sub(y2, big.NewInt(1)), new(big.Int).Add(new(big.Int).Mul(d, y2), big.NewInt(1)))
	result := point{big.NewInt(0), big.NewInt(1), big.NewInt(1), big.NewInt(0)}
	base := point{new(big.Int).Set(x), new(big.Int).Set(y), big.NewInt(1), mod(new(big.Int).Mul(x, y))}
	for bit := 0; bit < 253; bit++ {
		if k.Bit(bit) != 0 {
			result = add(result, base)
		}
		base = add(base, base)
	}
	var encoded *big.Int
	if chain == "monero" {
		zInv := inverse(result.z)
		x = mod(new(big.Int).Mul(result.x, zInv))
		y = mod(new(big.Int).Mul(result.y, zInv))
		encoded = new(big.Int).Set(y)
		if x.Bit(0) != 0 {
			encoded.SetBit(encoded, 255, 1)
		}
	} else {
		encoded = ristretto(result)
	}
	out := make([]byte, 32)
	encoded.FillBytes(out)
	reverse(out)
	return hex.EncodeToString(out), true
}

func ristretto(value point) *big.Int {
	x, y, z, t := value.x, value.y, value.z, value.t
	u1 := mod(new(big.Int).Mul(new(big.Int).Add(z, y), new(big.Int).Sub(z, y)))
	u2 := mod(new(big.Int).Mul(x, y))
	u2Squared := mod(new(big.Int).Mul(u2, u2))
	invsqrt := sqrtRatio(big.NewInt(1), mod(new(big.Int).Mul(u1, u2Squared)))
	den1 := mod(new(big.Int).Mul(invsqrt, u1))
	den2 := mod(new(big.Int).Mul(invsqrt, u2))
	zInv := mod(new(big.Int).Mul(new(big.Int).Mul(den1, den2), t))
	den := den2
	if mod(new(big.Int).Mul(t, zInv)).Bit(0) != 0 {
		x, y = mod(new(big.Int).Mul(y, i)), mod(new(big.Int).Mul(x, i))
		den = mod(new(big.Int).Mul(den1, inv))
	}
	if mod(new(big.Int).Mul(x, zInv)).Bit(0) != 0 {
		y = mod(new(big.Int).Neg(y))
	}
	return absolute(mod(new(big.Int).Mul(den, new(big.Int).Sub(z, y))))
}

func add(left, right point) point {
	a := mod(new(big.Int).Mul(new(big.Int).Sub(left.y, left.x), new(big.Int).Sub(right.y, right.x)))
	b := mod(new(big.Int).Mul(new(big.Int).Add(left.y, left.x), new(big.Int).Add(right.y, right.x)))
	c := mod(new(big.Int).Mul(new(big.Int).Mul(big.NewInt(2), d), new(big.Int).Mul(left.t, right.t)))
	doubleZ := mod(new(big.Int).Mul(big.NewInt(2), new(big.Int).Mul(left.z, right.z)))
	e := new(big.Int).Sub(b, a)
	f := new(big.Int).Sub(doubleZ, c)
	g := new(big.Int).Add(doubleZ, c)
	h := new(big.Int).Add(b, a)
	return point{
		mod(new(big.Int).Mul(e, f)),
		mod(new(big.Int).Mul(g, h)),
		mod(new(big.Int).Mul(f, g)),
		mod(new(big.Int).Mul(e, h)),
	}
}

func sqrtRatio(u, v *big.Int) *big.Int {
	v3 := mod(new(big.Int).Exp(v, big.NewInt(3), p))
	v7 := mod(new(big.Int).Exp(v, big.NewInt(7), p))
	uv7 := mod(new(big.Int).Mul(u, v7))
	r := mod(new(big.Int).Mul(new(big.Int).Mul(u, v3), new(big.Int).Exp(uv7, sqrtExp, p)))
	check := mod(new(big.Int).Mul(v, new(big.Int).Mul(r, r)))
	negativeU := mod(new(big.Int).Neg(u))
	negativeUI := mod(new(big.Int).Mul(negativeU, i))
	if check.Cmp(negativeU) == 0 || check.Cmp(negativeUI) == 0 {
		r = mod(new(big.Int).Mul(r, i))
	}
	return absolute(r)
}

func absolute(value *big.Int) *big.Int {
	value = mod(value)
	if value.Bit(0) != 0 {
		return mod(new(big.Int).Neg(value))
	}
	return value
}

func inverse(value *big.Int) *big.Int {
	return new(big.Int).Exp(mod(value), new(big.Int).Sub(p, big.NewInt(2)), p)
}

func mod(value *big.Int) *big.Int {
	return new(big.Int).Mod(value, p)
}

func integer(value string, base int) *big.Int {
	result, ok := new(big.Int).SetString(value, base)
	if !ok {
		panic(value)
	}
	return result
}

func littleInteger(value []byte) *big.Int {
	copyValue := append([]byte(nil), value...)
	reverse(copyValue)
	return new(big.Int).SetBytes(copyValue)
}

func reverse(value []byte) {
	for left, right := 0, len(value)-1; left < right; left, right = left+1, right-1 {
		value[left], value[right] = value[right], value[left]
	}
}

func decodeHex(value string) ([]byte, bool) {
	result := make([]byte, 0, len(value)/2)
	for index := 0; ; {
		for index < len(value) && asciiSpace(value[index]) {
			index++
		}
		if index == len(value) {
			return result, true
		}
		if index+1 >= len(value) {
			return nil, false
		}
		high, highOK := hexNibble(value[index])
		low, lowOK := hexNibble(value[index+1])
		if !highOK || !lowOK {
			return nil, false
		}
		result = append(result, high<<4|low)
		index += 2
	}
}

func asciiSpace(value byte) bool {
	return value == ' ' || value == '\t' || value == '\n' || value == '\r' || value == '\v' || value == '\f'
}

func hexNibble(value byte) (byte, bool) {
	switch {
	case value >= '0' && value <= '9':
		return value - '0', true
	case value >= 'a' && value <= 'f':
		return value - 'a' + 10, true
	case value >= 'A' && value <= 'F':
		return value - 'A' + 10, true
	default:
		return 0, false
	}
}
