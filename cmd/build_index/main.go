package main

import (
	"compress/gzip"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"strconv"
)

const (
	Dim      = 14
	IvfK     = 1024
	FixScale = 10000.0
)

type Item struct {
	Vector [Dim]float32
	Label  uint8
}

type RefObj struct {
	Vector []float64 `json:"vector"`
	Label  string    `json:"label"`
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintf(os.Stderr, "uso: %s <references.json|references.json.gz> <index.bin>\n", os.Args[0])
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "lendo references: %s\n", os.Args[1])
	items, err := parseReferences(os.Args[1])
	if err != nil || len(items) == 0 {
		fmt.Fprintf(os.Stderr, "falha lendo references\n")
		os.Exit(1)
	}
	N := len(items)
	fmt.Fprintf(os.Stderr, "vetores carregados: %d, memoria float+labels=%.2f MB\n", N, float64(N*Dim*4+N)/(1024*1024))

	sampleN := envU32("IVF_TRAIN_SAMPLE", 131072, IvfK, uint32(N))
	iters := envU32("IVF_TRAIN_ITERS", 10, 1, 256)
	fmt.Fprintf(os.Stderr, "treinando kmeans: K=%d sample=%d iters=%d\n", IvfK, sampleN, iters)

	centroids := make([]float32, IvfK*Dim)
	trainKMeans(centroids, items, sampleN, iters)

	assign := make([]int, N)
	counts := make([]int, IvfK)
	fmt.Fprintf(os.Stderr, "atribuindo %d referencias aos %d clusters...\n", N, IvfK)
	for i := 0; i < N; i++ {
		c := nearestCentroid(items[i].Vector[:], centroids)
		assign[i] = c
		counts[c]++
		if (i % 500000) == 0 && i > 0 {
			fmt.Fprintf(os.Stderr, "atribuido %d/%d\n", i, N)
		}
	}

	// Group vectors by cluster for AoSoA block packing
	clusterVecs := make([][]int, IvfK)
	for c := 0; c < IvfK; c++ {
		clusterVecs[c] = make([]int, 0, counts[c])
	}
	for i := 0; i < N; i++ {
		c := assign[i]
		clusterVecs[c] = append(clusterVecs[c], i)
	}

	// Compute block offsets: each cluster's vectors padded to multiples of 8
	blockOffsets := make([]uint32, IvfK+1)
	blockOffsets[0] = 0
	for c := 0; c < IvfK; c++ {
		sz := uint32(counts[c])
		blocks := (sz + 7) / 8
		blockOffsets[c+1] = blockOffsets[c] + blocks
	}
	totalBlocks := int(blockOffsets[IvfK])
	paddedN := totalBlocks * 8

	// AoSoA blocks: each block is 8 vectors * 14 dims = 112 int16
	// Layout within block: dim0[0..7], dim1[0..7], ..., dim13[0..7]
	outBlocks := make([]int16, totalBlocks*112)
	outLabels := make([]uint8, paddedN)
	for i := range outBlocks {
		outBlocks[i] = math.MaxInt16 // sentinel
	}

	fmt.Fprintf(os.Stderr, "empacotando AoSoA: %d blocos (%d vecs, %.2f MB)...\n",
		totalBlocks, totalBlocks*112, float64(totalBlocks*112*2)/(1024*1024))

	for c := 0; c < IvfK; c++ {
		blockStart := int(blockOffsets[c])
		nBlocks := int(blockOffsets[c+1] - blockOffsets[c])
		vecs := clusterVecs[c]
		for bk := 0; bk < nBlocks; bk++ {
			blockBase := (blockStart + bk) * 112
			labelBase := (blockStart + bk) * 8
			for slot := 0; slot < 8; slot++ {
				vi := bk*8 + slot
				if vi < len(vecs) {
					v := items[vecs[vi]].Vector
					for d := 0; d < Dim; d++ {
						outBlocks[blockBase+d*8+slot] = quantizeI16(v[d])
					}
					outLabels[labelBase+slot] = items[vecs[vi]].Label
				}
			}
		}
	}

	// Transpose centroids: row-major → column-major (dim-major)
	centroidsT := make([]float32, IvfK*Dim)
	for d := 0; d < Dim; d++ {
		for c := 0; c < IvfK; c++ {
			centroidsT[d*IvfK+c] = centroids[c*Dim+d]
		}
	}

	fmt.Fprintf(os.Stderr, "gravando %s...\n", os.Args[2])
	if err := writeIndexIVF7(os.Args[2], uint32(N), centroidsT, blockOffsets, outLabels, outBlocks); err != nil {
		fmt.Fprintf(os.Stderr, "falha gravando index\n")
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "ok: IVF7 %s (N=%d K=%d blocks=%d padded=%d)\n",
		os.Args[2], N, IvfK, totalBlocks, paddedN)
}

func parseReferences(path string) ([]Item, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var r io.Reader = f
	if len(path) > 3 && path[len(path)-3:] == ".gz" {
		gz, err := gzip.NewReader(f)
		if err != nil {
			return nil, err
		}
		defer gz.Close()
		r = gz
	}

	dec := json.NewDecoder(r)
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	if tok != json.Delim('[') {
		return nil, fmt.Errorf("expected array")
	}

	var items []Item
	for dec.More() {
		var obj RefObj
		if err := dec.Decode(&obj); err != nil {
			return nil, err
		}
		if len(obj.Vector) != Dim {
			continue
		}
		var it Item
		for j := 0; j < Dim; j++ {
			it.Vector[j] = float32(obj.Vector[j])
		}
		if obj.Label == "fraud" {
			it.Label = 1
		} else {
			it.Label = 0
		}
		items = append(items, it)
		if len(items)%500000 == 0 {
			fmt.Fprintf(os.Stderr, "parseados %d vetores\n", len(items))
		}
	}
	return items, nil
}

func trainKMeans(centroids []float32, items []Item, sampleN, iters uint32) {
	N := len(items)
	if int(sampleN) > N {
		sampleN = uint32(N)
	}
	sample := make([]int, sampleN)
	for i := uint32(0); i < sampleN; i++ {
		sample[i] = int((uint64(i) * uint64(N)) / uint64(sampleN))
	}
	for c := 0; c < IvfK; c++ {
		si := (uint64(c) * uint64(sampleN)) / uint64(IvfK)
		if si >= uint64(sampleN) {
			si = uint64(sampleN) - 1
		}
		copy(centroids[c*Dim:c*Dim+Dim], items[sample[si]].Vector[:])
	}

	sums := make([]float32, IvfK*Dim)
	counts := make([]int, IvfK)

	for it := uint32(0); it < iters; it++ {
		for i := range sums {
			sums[i] = 0
		}
		for i := range counts {
			counts[i] = 0
		}
		for _, idx := range sample {
			c := nearestCentroid(items[idx].Vector[:], centroids)
			v := items[idx].Vector
			sum := sums[c*Dim : c*Dim+Dim]
			for j := 0; j < Dim; j++ {
				sum[j] += v[j]
			}
			counts[c]++
		}
		empty := 0
		for c := 0; c < IvfK; c++ {
			if counts[c] == 0 {
				empty++
				continue
			}
			inv := 1.0 / float32(counts[c])
			cc := centroids[c*Dim : c*Dim+Dim]
			sum := sums[c*Dim : c*Dim+Dim]
			for j := 0; j < Dim; j++ {
				cc[j] = sum[j] * inv
			}
		}
		fmt.Fprintf(os.Stderr, "kmeans iter %d/%d sample=%d empty=%d\n", it+1, iters, sampleN, empty)
	}
}

func nearestCentroid(v []float32, centroids []float32) int {
	best := 0
	bestD := float32(math.MaxFloat32)
	for c := 0; c < IvfK; c++ {
		cc := centroids[c*Dim : c*Dim+Dim]
		var d float32
		for j := 0; j < Dim; j++ {
			diff := v[j] - cc[j]
			d += diff * diff
		}
		if d < bestD {
			bestD = d
			best = c
		}
	}
	return best
}

func quantizeI16(x float32) int16 {
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

func writeIndexIVF7(path string, n uint32, centroidsT []float32, blockOffsets []uint32, outLabels []uint8, outBlocks []int16) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	binary.Write(f, binary.LittleEndian, []byte("IVF7"))
	binary.Write(f, binary.LittleEndian, n)
	binary.Write(f, binary.LittleEndian, uint32(IvfK))
	binary.Write(f, binary.LittleEndian, uint32(Dim))
	binary.Write(f, binary.LittleEndian, uint32(Dim))
	binary.Write(f, binary.LittleEndian, float32(FixScale))
	binary.Write(f, binary.LittleEndian, centroidsT)
	binary.Write(f, binary.LittleEndian, blockOffsets)
	binary.Write(f, binary.LittleEndian, outLabels)
	binary.Write(f, binary.LittleEndian, outBlocks)
	return f.Sync()
}

func envU32(name string, def, minv, maxv uint32) uint32 {
	e := os.Getenv(name)
	if e == "" {
		return def
	}
	v, err := strconv.ParseUint(e, 10, 32)
	if err != nil {
		return def
	}
	uv := uint32(v)
	if uv < minv {
		return minv
	}
	if uv > maxv {
		return maxv
	}
	return uv
}
