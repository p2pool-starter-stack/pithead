package address

import (
	"encoding/hex"
	"math/big"
	"unicode/utf8"
)

const tariBase58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

const tariEmoji = "🐢📟🌈🌊🎯🐋🌙🤔🌕⭐🎋🌰🌴🌵🌲🌸🌹🌻🌽🍀🍁🍄🥑🍆🍇🍈🍉🍊🍋🍌🍍🍎" +
	"🍐🍑🍒🍓🍔🍕🍗🍚🍞🍟🥝🍣🍦🍩🍪🍫🍬🍭🍯🥐🍳🥄🍵🍶🍷🍸🍾🍺🍼🎀🎁🎂" +
	"🎃🤖🎈🎉🎒🎓🎠🎡🎢🎣🎤🎥🎧🎨🎩🎪🎬🎭🎮🎰🎱🎲🎳🎵🎷🎸🎹🎺🎻🎼🎽🎾" +
	"🎿🏀🏁🏆🏈⚽🏠🏥🏦🏭🏰🐀🐉🐊🐌🐍🦁🐐🐑🐔🙈🐗🐘🐙🐚🐛🐜🐝🐞🦋🐣🐨" +
	"🦀🐪🐬🐭🐮🐯🐰🦆🦂🐴🐵🐶🐷🐸🐺🐻🐼🐽🐾👀👅👑👒🧢💅👕👖👗👘👙💃👛" +
	"👞👟👠🥊👢👣🤡👻👽👾🤠👃💄💈💉💊💋👂💍💎💐💔🔒🧩💡💣💤💦💨💩➕💯" +
	"💰💳💵💺💻💼📈📜📌📎📖📿📡⏰📱📷🔋🔌🚰🔑🔔🔥🔦🔧🔨🔩🔪🔫🔬🔭🔮🔱" +
	"🗽😂😇😈🤑😍😎😱😷🤢👍👶🚀🚁🚂🚚🚑🚒🚓🛵🚗🚜🚢🚦🚧🚨🚪🚫🚲🚽🚿🧲"

func Tari(value string, verify bool, keyOnly bool) string {
	if !verify {
		return "unchecked"
	}
	if !utf8.ValidString(value) {
		return "invalid"
	}

	raw := decodeTari(value)
	if len(raw) != 35 && (len(raw) < 67 || len(raw) > 323) {
		return "invalid"
	}
	if tariDammSum(raw) != 0 {
		return "checksum"
	}
	if raw[0] != 0 {
		switch raw[0] {
		case 0x01, 0x02, 0x10, 0x24, 0x26:
			return "network"
		default:
			return "invalid"
		}
	}
	if raw[1]&^byte(0b111) != 0 {
		return "invalid"
	}
	if !keyOnly {
		return "ok"
	}
	if len(raw) == 35 {
		return hex.EncodeToString(append(raw[:1:1], raw[2:34]...))
	}
	return hex.EncodeToString(append(raw[:1:1], raw[2:66]...))
}

func decodeTari(value string) []byte {
	ascii := true
	for _, current := range value {
		if current >= 128 {
			ascii = false
			break
		}
	}
	if ascii {
		if len(value) < 45 {
			return nil
		}
		first := decodeTariBase58(value[:1])
		second := decodeTariBase58(value[1:2])
		rest := decodeTariBase58(value[2:])
		if first == nil || second == nil || rest == nil {
			return nil
		}
		return append(append(first, second...), rest...)
	}

	alphabet := []rune(tariEmoji)
	raw := make([]byte, 0, utf8.RuneCountInString(value))
	for _, current := range value {
		index := -1
		for i, candidate := range alphabet {
			if candidate == current {
				index = i
				break
			}
		}
		if index < 0 {
			return nil
		}
		raw = append(raw, byte(index))
	}
	return raw
}

func decodeTariBase58(value string) []byte {
	n := new(big.Int)
	for i := 0; i < len(value); i++ {
		digit := indexByte(tariBase58, value[i])
		if digit < 0 {
			return nil
		}
		n.Mul(n, big.NewInt(58))
		n.Add(n, big.NewInt(int64(digit)))
	}

	leading := 0
	for leading < len(value) && value[leading] == '1' {
		leading++
	}
	return append(make([]byte, leading), n.Bytes()...)
}

func tariDammSum(data []byte) byte {
	var result byte
	for _, value := range data {
		result ^= value
		overflow := result & 0x80
		result <<= 1
		if overflow != 0 {
			result ^= 27
		}
	}
	return result
}
