package main

import (
	"encoding/json"
	"fmt"
	"os"
	"rinha-2026/internal/config"
	"rinha-2026/internal/ivfsearch"
	"rinha-2026/internal/mccrisk"
	"rinha-2026/internal/vectorizer"
)

func main() {
	cfg := config.Load()
	mccTable := mccrisk.Load(cfg.MccRiskPath)

	if err := ivfsearch.BridgeLoadIndex(cfg.IndexPath); err != nil {
		panic(err)
	}

	data, err := os.ReadFile("../test/test-data.json")
	if err != nil {
		panic(err)
	}

	var testData map[string]interface{}
	if err := json.Unmarshal(data, &testData); err != nil {
		panic(err)
	}

	entries := testData["entries"].([]interface{})
	fmt.Printf("Total entries: %d\n", len(entries))

	for _, candidates := range []int{0, 5000, 8000, 10000, 11700} {
		ivfsearch.BridgeSetParams(cfg.IvfNprobe, candidates)

		fp, fn, skipped := 0, 0, 0
		for _, e := range entries {
			entry := e.(map[string]interface{})
			request := entry["request"]
			expectedApproved := entry["expected_approved"].(bool)

			payload, _ := json.Marshal(request)
			q, ok := vectorizer.Build(payload, cfg, mccTable)
			if !ok {
				skipped++
				continue
			}
			votes := ivfsearch.BridgeSearch(q)
			approved := votes < 3

			if expectedApproved && !approved {
				fp++
			}
			if !expectedApproved && approved {
				fn++
			}
		}

		fmt.Printf("CANDIDATES=%5d: fp=%d fn=%d skipped=%d total_errors=%d\n", candidates, fp, fn, skipped, fp+fn)
	}
}
