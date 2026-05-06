package main

import (
	"fmt"
	"time"

	"rinha-2026/internal/config"
	"rinha-2026/internal/httpresp"
	"rinha-2026/internal/ivfsearch"
	"rinha-2026/internal/mccrisk"
	"rinha-2026/internal/vectorizer"
)

func main() {
	cfg := config.Load()
	httpresp.Init()
	mccTable := mccrisk.Load(cfg.MccRiskPath)

	if err := ivfsearch.BridgeLoadIndex(cfg.IndexPath); err != nil {
		panic(err)
	}
	ivfsearch.BridgeSetParams(cfg.IvfNprobe, cfg.Candidates)

	body := []byte(`{"transaction":{"amount":1000,"installments":1,"requested_at":"2024-01-15T10:30:00Z"},"customer":{"avg_amount":500,"tx_count_24h":2,"known_merchants":[]},"merchant":{"id":"merch123","mcc":"5411","avg_amount":800},"terminal":{"is_online":true,"card_present":true,"km_from_home":5}}`)

	// Warmup
	for i := 0; i < 1000; i++ {
		q, _ := vectorizer.Build(body, cfg, mccTable)
		ivfsearch.BridgeSearch(q)
	}

	const n = 10000

	// Benchmark vectorizer only
	start := time.Now()
	for i := 0; i < n; i++ {
		vectorizer.Build(body, cfg, mccTable)
	}
	vecTime := time.Since(start)

	// Benchmark bridge with different candidates
	q, _ := vectorizer.Build(body, cfg, mccTable)
	for _, cand := range []int{0, 5000, 10000, 20000, 50000} {
		ivfsearch.BridgeSetParams(cfg.IvfNprobe, cand)
		start = time.Now()
		for i := 0; i < n; i++ {
			ivfsearch.BridgeSearch(q)
		}
		t := time.Since(start)
		fmt.Printf("bridge(cand=%5d): %v per call (%d calls)\n", cand, t/time.Duration(n), n)
	}

	fmt.Printf("\nvectorizer:  %v per call (%d calls)\n", vecTime/time.Duration(n), n)
}
