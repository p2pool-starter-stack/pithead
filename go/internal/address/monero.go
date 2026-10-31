package address

import (
	"encoding/hex"
	"math/big"
	"math/bits"
)

const moneroBase58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

var moneroBlockSizes = map[int]int{
	11: 8,
	10: 7,
	9:  6,
	7:  5,
	6:  4,
	5:  3,
	3:  2,
	2:  1,
}

func Monero(value string, verify bool, keyOnly bool) string {
	shape := moneroShape(value)
	if shape == "invalid" || !verify {
		return shape
	}

	raw := decodeMoneroBase58(value)
	if len(raw) < 5 {
		return "invalid"
	}
	body, checksum := raw[:len(raw)-4], raw[len(raw)-4:]
	digest := legacyKeccak256(body)
	if string(digest[:4]) != string(checksum) {
		return "checksum"
	}

	kind, length := "", 0
	switch body[0] {
	case 18:
		kind, length = "primary", 65
	case 19:
		kind, length = "integrated", 73
	case 42:
		kind, length = "subaddress", 65
	}
	if len(body) != length || kind == "" {
		return "invalid"
	}
	if keyOnly {
		return hex.EncodeToString(body[33:65])
	}
	return kind
}

func moneroShape(value string) string {
	if value == "" {
		return "invalid"
	}
	length := len(value)
	switch value[0] {
	case '4':
		switch length {
		case 95:
			return "primary"
		case 106:
			return "integrated"
		}
	case '8':
		if length == 95 {
			return "subaddress"
		}
	}
	return "invalid"
}

func decodeMoneroBase58(value string) []byte {
	decoded := make([]byte, 0, len(value))
	for offset := 0; offset < len(value); offset += 11 {
		end := min(offset+11, len(value))
		block := value[offset:end]
		size, ok := moneroBlockSizes[len(block)]
		if !ok {
			return nil
		}

		n := new(big.Int)
		for i := 0; i < len(block); i++ {
			digit := indexByte(moneroBase58, block[i])
			if digit < 0 {
				return nil
			}
			n.Mul(n, big.NewInt(58))
			n.Add(n, big.NewInt(int64(digit)))
		}
		if n.BitLen() > size*8 {
			return nil
		}
		bytes := n.Bytes()
		decoded = append(decoded, make([]byte, size-len(bytes))...)
		decoded = append(decoded, bytes...)
	}
	return decoded
}

func legacyKeccak256(data []byte) [32]byte {
	var state [5][5]uint64
	padding := append(append([]byte(nil), data...), 1)
	for len(padding)%136 != 0 {
		padding = append(padding, 0)
	}
	padding[len(padding)-1] |= 0x80
	for offset := 0; offset < len(padding); offset += 136 {
		for i := 0; i < 17; i++ {
			var word uint64
			for j := 0; j < 8; j++ {
				word |= uint64(padding[offset+8*i+j]) << (8 * j)
			}
			state[i%5][i/5] ^= word
		}
		state = keccakPermutation(state)
	}

	var digest [32]byte
	for i := 0; i < 4; i++ {
		word := state[i%5][i/5]
		for j := 0; j < 8; j++ {
			digest[8*i+j] = byte(word >> (8 * j))
		}
	}
	return digest
}

var keccakRoundConstants = [24]uint64{
	0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
	0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
	0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
	0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
	0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
	0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
}

var keccakRotations = [5][5]int{
	{0, 36, 3, 41, 18},
	{1, 44, 10, 45, 2},
	{62, 6, 43, 15, 61},
	{28, 55, 25, 21, 56},
	{27, 20, 39, 8, 14},
}

func keccakPermutation(state [5][5]uint64) [5][5]uint64 {
	for _, round := range keccakRoundConstants {
		var columns, delta [5]uint64
		for x := 0; x < 5; x++ {
			columns[x] = state[x][0] ^ state[x][1] ^ state[x][2] ^ state[x][3] ^ state[x][4]
		}
		for x := 0; x < 5; x++ {
			delta[x] = columns[(x+4)%5] ^ bits.RotateLeft64(columns[(x+1)%5], 1)
			for y := 0; y < 5; y++ {
				state[x][y] ^= delta[x]
			}
		}

		var rotated [5][5]uint64
		for x := 0; x < 5; x++ {
			for y := 0; y < 5; y++ {
				rotated[y][(2*x+3*y)%5] = bits.RotateLeft64(state[x][y], keccakRotations[x][y])
			}
		}
		for x := 0; x < 5; x++ {
			for y := 0; y < 5; y++ {
				state[x][y] = rotated[x][y] ^ (^rotated[(x+1)%5][y] & rotated[(x+2)%5][y])
			}
		}
		state[0][0] ^= round
	}
	return state
}

func indexByte(alphabet string, value byte) int {
	for i := 0; i < len(alphabet); i++ {
		if alphabet[i] == value {
			return i
		}
	}
	return -1
}
