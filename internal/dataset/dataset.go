package dataset

import (
	"encoding/binary"
	"fmt"
	"math"
	"os"
)

const (
	Dim         = 14
	IvfClusters = 256
	FixScale    = 10000.0
)

type Dataset struct {
	N            int
	Dim          [14][]int16
	Labels       []uint8
	OrigIDs      []uint32
	Centroids    []float32 // [IvfClusters][Dim]
	BBoxMin      []int16   // [IvfClusters][Dim]
	BBoxMax      []int16   // [IvfClusters][Dim]
	ClusterStart [IvfClusters]int
	ClusterEnd   [IvfClusters]int
}

func LoadIndex(path string) (*Dataset, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var magic [4]byte
	var n, k, d, stride uint32
	var scale float32
	if err := binary.Read(f, binary.LittleEndian, &magic); err != nil {
		return nil, err
	}
	if string(magic[:]) != "IVF6" {
		return nil, fmt.Errorf("index invalido ou magic diferente de IVF6: %s", path)
	}
	if err := binary.Read(f, binary.LittleEndian, &n); err != nil {
		return nil, err
	}
	if err := binary.Read(f, binary.LittleEndian, &k); err != nil {
		return nil, err
	}
	if err := binary.Read(f, binary.LittleEndian, &d); err != nil {
		return nil, err
	}
	if err := binary.Read(f, binary.LittleEndian, &stride); err != nil {
		return nil, err
	}
	if err := binary.Read(f, binary.LittleEndian, &scale); err != nil {
		return nil, err
	}

	if k != IvfClusters || d != Dim || stride != Dim {
		return nil, fmt.Errorf("index incompativel: k=%d d=%d stride=%d esperado k=%d d=%d stride=%d", k, d, stride, IvfClusters, Dim, Dim)
	}
	if math.Abs(float64(scale)-FixScale) > 0.01 {
		return nil, fmt.Errorf("index incompativel: scale=%.1f esperado=%.1f", scale, FixScale)
	}

	ds := &Dataset{N: int(n)}
	ds.Centroids = make([]float32, IvfClusters*Dim)
	ds.BBoxMin = make([]int16, IvfClusters*Dim)
	ds.BBoxMax = make([]int16, IvfClusters*Dim)

	if err := binary.Read(f, binary.LittleEndian, ds.Centroids); err != nil {
		return nil, err
	}
	if err := binary.Read(f, binary.LittleEndian, ds.BBoxMin); err != nil {
		return nil, err
	}
	if err := binary.Read(f, binary.LittleEndian, ds.BBoxMax); err != nil {
		return nil, err
	}

	offsets := make([]uint32, IvfClusters+1)
	if err := binary.Read(f, binary.LittleEndian, offsets); err != nil {
		return nil, err
	}
	for c := 0; c < IvfClusters; c++ {
		ds.ClusterStart[c] = int(offsets[c])
		ds.ClusterEnd[c] = int(offsets[c+1])
	}

	for j := 0; j < Dim; j++ {
		ds.Dim[j] = make([]int16, n)
	}

	const chunk = 16384
	tmp := make([]int16, chunk*Dim)
	done := uint32(0)
	for done < n {
		take := n - done
		if take > chunk {
			take = chunk
		}
		if err := binary.Read(f, binary.LittleEndian, tmp[:take*Dim]); err != nil {
			return nil, err
		}
		for i := uint32(0); i < take; i++ {
			for j := 0; j < Dim; j++ {
				ds.Dim[j][done+i] = tmp[i*uint32(Dim)+uint32(j)]
			}
		}
		done += take
	}

	ds.Labels = make([]uint8, n)
	if err := binary.Read(f, binary.LittleEndian, ds.Labels); err != nil {
		return nil, err
	}

	ds.OrigIDs = make([]uint32, n)
	if err := binary.Read(f, binary.LittleEndian, ds.OrigIDs); err != nil {
		return nil, err
	}

	mb := float64(int(n)*Dim*2+int(n)+int(n)*4+IvfClusters*Dim*(4+2+2)) / (1024.0 * 1024.0)
	fmt.Fprintf(os.Stderr, "index IVF6 carregado: N=%d K=%d scale=%.1f memoria=%.2f MB\n", n, k, scale, mb)
	return ds, nil
}
