package ivfsearch

import (
	"math"
	"rinha-2026/internal/config"
	"rinha-2026/internal/dataset"
)

const (
	Dim          = dataset.Dim
	IvfClusters  = dataset.IvfClusters
	IvfMaxNprobe = 512
	KNeighbors   = 5
	FixScale     = dataset.FixScale
)

func QuantizeFixed(x float32) int16 {
	if x < -1.0 {
		x = -1.0
	}
	if x > 1.0 {
		x = 1.0
	}
	scaled := x * FixScale
	if scaled >= 0 {
		scaled += 0.5
	} else {
		scaled -= 0.5
	}
	if scaled < -10000.0 {
		scaled = -10000.0
	}
	if scaled > 10000.0 {
		scaled = 10000.0
	}
	return int16(scaled)
}

func sqdiffI16(a, b int16) uint64 {
	d := int32(a) - int32(b)
	return uint64(int64(d) * int64(d))
}

func isWorsePair(da uint64, ia uint32, db uint64, ib uint32) bool {
	return da > db || (da == db && ia > ib)
}

func isBetterPair(da uint64, ia uint32, db uint64, ib uint32) bool {
	return da < db || (da == db && ia < ib)
}

func worstIndex5(d [5]uint64, id [5]uint32) int {
	w := 0
	if isWorsePair(d[1], id[1], d[w], id[w]) {
		w = 1
	}
	if isWorsePair(d[2], id[2], d[w], id[w]) {
		w = 2
	}
	if isWorsePair(d[3], id[3], d[w], id[w]) {
		w = 3
	}
	if isWorsePair(d[4], id[4], d[w], id[w]) {
		w = 4
	}
	return w
}

func tryInsertTop5(d uint64, label uint8, origID uint32,
	bestD *[5]uint64, bestL *[5]uint8, bestID *[5]uint32,
	worst *int, worstD *uint64, worstID *uint32) {

	if isBetterPair(d, origID, *worstD, *worstID) {
		bestD[*worst] = d
		bestL[*worst] = label
		bestID[*worst] = origID
		*worst = worstIndex5(*bestD, *bestID)
		*worstD = bestD[*worst]
		*worstID = bestID[*worst]
	}
}

func centroidSqDist(q [Dim]float32, c int, ds *dataset.Dataset) float32 {
	cent := ds.Centroids[c*Dim : c*Dim+Dim]
	var s float32
	for j := 0; j < Dim; j++ {
		d := q[j] - cent[j]
		s += d * d
	}
	return s
}

func bboxLowerBound(q [Dim]int16, c int, ds *dataset.Dataset) uint64 {
	mn := ds.BBoxMin[c*Dim : c*Dim+Dim]
	mx := ds.BBoxMax[c*Dim : c*Dim+Dim]
	var s uint64
	for j := 0; j < Dim; j++ {
		var d int32
		if q[j] < mn[j] {
			d = int32(mn[j]) - int32(q[j])
		} else if q[j] > mx[j] {
			d = int32(q[j]) - int32(mx[j])
		} else {
			d = 0
		}
		s += uint64(int64(d) * int64(d))
	}
	return s
}

func insertProbeCluster(cluster int, penalty float32, bestC []int, bestP []float32, nprobe int) {
	if penalty >= bestP[nprobe-1] {
		return
	}
	pos := nprobe - 1
	for pos > 0 && penalty < bestP[pos-1] {
		pos--
	}
	for i := nprobe - 1; i > pos; i-- {
		bestP[i] = bestP[i-1]
		bestC[i] = bestC[i-1]
	}
	bestP[pos] = penalty
	bestC[pos] = cluster
}

func scanRange(start, end int, q [Dim]int16, ds *dataset.Dataset,
	bestD *[5]uint64, bestL *[5]uint8, bestID *[5]uint32,
	worst *int, worstD *uint64, worstID *uint32) {

	q0, q1, q2, q3, q4, q5, q6, q7 := q[0], q[1], q[2], q[3], q[4], q[5], q[6], q[7]
	q8, q9, q10, q11, q12, q13 := q[8], q[9], q[10], q[11], q[12], q[13]

	d0 := ds.Dim[0]
	d1 := ds.Dim[1]
	d2 := ds.Dim[2]
	d3 := ds.Dim[3]
	d4 := ds.Dim[4]
	d5 := ds.Dim[5]
	d6 := ds.Dim[6]
	d7 := ds.Dim[7]
	d8 := ds.Dim[8]
	d9 := ds.Dim[9]
	d10 := ds.Dim[10]
	d11 := ds.Dim[11]
	d12 := ds.Dim[12]
	d13 := ds.Dim[13]

	labels := ds.Labels
	ids := ds.OrigIDs

	for i := start; i < end; i++ {
		var dist uint64
		dist += sqdiffI16(q5, d5[i])
		if dist > *worstD {
			continue
		}
		dist += sqdiffI16(q6, d6[i])
		if dist > *worstD {
			continue
		}
		dist += sqdiffI16(q2, d2[i])
		if dist > *worstD {
			continue
		}
		dist += sqdiffI16(q0, d0[i])
		if dist > *worstD {
			continue
		}
		dist += sqdiffI16(q7, d7[i])
		if dist > *worstD {
			continue
		}
		dist += sqdiffI16(q8, d8[i])
		if dist > *worstD {
			continue
		}
		dist += sqdiffI16(q11, d11[i])
		if dist > *worstD {
			continue
		}
		dist += sqdiffI16(q12, d12[i])
		if dist > *worstD {
			continue
		}
		dist += sqdiffI16(q9, d9[i])
		if dist > *worstD {
			continue
		}
		dist += sqdiffI16(q10, d10[i])
		if dist > *worstD {
			continue
		}
		dist += sqdiffI16(q1, d1[i])
		if dist > *worstD {
			continue
		}
		dist += sqdiffI16(q13, d13[i])
		if dist > *worstD {
			continue
		}
		dist += sqdiffI16(q3, d3[i])
		if dist > *worstD {
			continue
		}
		dist += sqdiffI16(q4, d4[i])

		oid := ids[i]
		if isBetterPair(dist, oid, *worstD, *worstID) {
			tryInsertTop5(dist, labels[i], oid, bestD, bestL, bestID, worst, worstD, worstID)
		}
	}
}

func countFrauds5(bestL [5]uint8) int {
	c := 0
	for i := 0; i < 5; i++ {
		if bestL[i] == 1 {
			c++
		}
	}
	return c
}

func FraudVotes(qFloat [Dim]float32, ds *dataset.Dataset, cfg *config.Config) int {
	var q [Dim]int16
	var qGrid [Dim]float32
	for j := 0; j < Dim; j++ {
		q[j] = QuantizeFixed(qFloat[j])
		qGrid[j] = float32(q[j]) / FixScale
	}

	nprobe := cfg.IvfNprobe
	if nprobe < 1 {
		nprobe = 1
	}
	if nprobe > IvfMaxNprobe {
		nprobe = IvfMaxNprobe
	}
	if nprobe > IvfClusters {
		nprobe = IvfClusters
	}

	var bestC [IvfMaxNprobe]int
	var bestP [IvfMaxNprobe]float32
	for i := 0; i < nprobe; i++ {
		bestC[i] = -1
		bestP[i] = math.MaxFloat32
	}
	for c := 0; c < IvfClusters; c++ {
		insertProbeCluster(c, centroidSqDist(qGrid, c, ds), bestC[:nprobe], bestP[:nprobe], nprobe)
	}

	var bestD [5]uint64
	var bestL [5]uint8
	var bestID [5]uint32
	for i := 0; i < 5; i++ {
		bestD[i] = math.MaxUint64
		bestID[i] = math.MaxUint32
	}
	worst := 0
	worstD := uint64(math.MaxUint64)
	worstID := uint32(math.MaxUint32)
	scanned := 0
	var scannedCluster [IvfClusters]bool

	for pi := 0; pi < nprobe; pi++ {
		c := bestC[pi]
		if c < 0 {
			continue
		}
		start := ds.ClusterStart[c]
		end := ds.ClusterEnd[c]
		sz := end - start
		if sz <= 0 {
			continue
		}
		scannedCluster[c] = true
		if cfg.Candidates > 0 && scanned+sz > cfg.Candidates {
			remaining := cfg.Candidates - scanned
			if remaining <= 0 {
				break
			}
			end = start + remaining
			sz = remaining
		}
		scanRange(start, end, q, ds, &bestD, &bestL, &bestID, &worst, &worstD, &worstID)
		scanned += sz
		if cfg.Candidates > 0 && scanned >= cfg.Candidates {
			break
		}
	}

	if cfg.Candidates <= 0 {
		for c := 0; c < IvfClusters; c++ {
			if scannedCluster[c] {
				continue
			}
			start := ds.ClusterStart[c]
			end := ds.ClusterEnd[c]
			if end <= start {
				continue
			}
			if bboxLowerBound(q, c, ds) <= worstD {
				scanRange(start, end, q, ds, &bestD, &bestL, &bestID, &worst, &worstD, &worstID)
			}
		}
	}

	return countFrauds5(bestL)
}
