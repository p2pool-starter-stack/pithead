package domain

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

type numericTier struct {
	name      string
	threshold float64
}

func numericTiers(tiers []Tier) ([]numericTier, error) {
	result := make([]numericTier, 0, len(tiers))
	for _, tier := range tiers {
		threshold, err := number(tier.Threshold)
		if err != nil {
			return nil, err
		}
		result = append(result, numericTier{name: tier.Name, threshold: threshold})
	}
	return result, nil
}

func tierInfo(hashrate float64, tiers []numericTier) (string, float64) {
	ordered := append([]numericTier(nil), tiers...)
	sort.SliceStable(ordered, func(i, j int) bool {
		return ordered[i].threshold > ordered[j].threshold
	})
	for _, tier := range ordered {
		if tier.threshold > 0 && hashrate >= tier.threshold {
			name := strings.ReplaceAll(strings.ReplaceAll(tier.name, "donor_", ""), "_", " ")
			words := strings.Split(name, " ")
			for i, word := range words {
				letters := []rune(word)
				if len(letters) != 0 {
					words[i] = strings.ToUpper(string(letters[0])) + strings.ToLower(string(letters[1:]))
				}
			}
			return fmt.Sprintf("%s (%s+)", strings.Join(words, " "), formatHashrate(tier.threshold)), tier.threshold
		}
	}
	return "None", 0
}

func formatHashrate(value float64) string {
	switch {
	case value >= 1_000_000_000:
		return fmt.Sprintf("%.2f GH/s", value/1_000_000_000)
	case value >= 1_000_000:
		return fmt.Sprintf("%.2f MH/s", value/1_000_000)
	case value >= 1_000:
		return fmt.Sprintf("%.2f kH/s", value/1_000)
	default:
		return fmt.Sprintf("%.2f H/s", value)
	}
}

func configuredThreshold(tiers []numericTier, donationLevel string) float64 {
	positive := make([]float64, 0, len(tiers))
	for _, tier := range tiers {
		if tier.threshold > 0 {
			positive = append(positive, tier.threshold)
		}
	}
	if len(positive) == 0 {
		return 0
	}
	sort.Float64s(positive)
	level := strings.ToLower(strings.TrimSpace(donationLevel))
	if level == "" {
		level = "lowest"
	}
	switch level {
	case "lowest":
		return positive[0]
	case "auto", "highest":
		return positive[len(positive)-1]
	}
	for _, tier := range tiers {
		name := strings.ToLower(strings.ReplaceAll(strings.ReplaceAll(tier.name, "donor_", ""), "_", ""))
		if name == "" {
			name = "donor"
		}
		if level == name || level == strings.ToLower(tier.name) {
			return tier.threshold
		}
	}
	if threshold, err := strconv.ParseFloat(level, 64); err == nil {
		return threshold
	}
	return positive[0]
}

func targetThreshold(tiers []numericTier, stableHashrate float64, level string, maxFraction float64) (float64, bool) {
	_, sustainableThreshold := tierInfo(stableHashrate*maxFraction, tiers)
	normalized := strings.ToLower(strings.TrimSpace(level))
	if normalized == "" {
		normalized = "auto"
	}
	target := sustainableThreshold
	if normalized != "auto" && normalized != "highest" {
		target = configuredThreshold(tiers, normalized)
	}
	return target, target > 0 && stableHashrate*maxFraction >= target
}
