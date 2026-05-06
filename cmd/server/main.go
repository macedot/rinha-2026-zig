package main

import (
	"fmt"
	"log"
	"net"
	"os"
	"rinha-2026/internal/config"
	"rinha-2026/internal/httpresp"
	"rinha-2026/internal/ivfsearch"
	"rinha-2026/internal/mccrisk"
	"rinha-2026/internal/vectorizer"

	"github.com/valyala/fasthttp"
	"go.uber.org/automaxprocs/maxprocs"
)

var (
	cfg      *config.Config
	mccTable *mccrisk.Table
)

func main() {
	if _, err := maxprocs.Set(); err != nil {
		log.Printf("automaxprocs: %v", err)
	}
	cfg = config.Load()
	httpresp.Init()
	mccTable = mccrisk.Load(cfg.MccRiskPath)

	if err := ivfsearch.BridgeLoadIndex(cfg.IndexPath); err != nil {
		fmt.Fprintf(os.Stderr, "falha carregando INDEX_PATH=%s\n", cfg.IndexPath)
		log.Fatal(err)
	}
	ivfsearch.BridgeSetParams(cfg.IvfNprobe, cfg.IvfFullNprobe, cfg.Candidates)

	/* Warm CPU caches with random queries */
	fmt.Fprintf(os.Stderr, "warming caches...\n")
	for i := 0; i < 500; i++ {
		q := [14]float32{
			float32(i%10000) / 10000.0, float32(i%12) / 12.0,
			float32(i%10) / 10.0, float32(i%24) / 23.0, float32(i%7) / 6.0,
			-1.0, -1.0, float32(i%1000) / 1000.0, float32(i%20) / 20.0,
			0.0, 1.0, 1.0, 0.5, float32(i%10000) / 10000.0,
		}
		ivfsearch.BridgeSearch(q)
	}
	fmt.Fprintf(os.Stderr, "cache warmup done\n")

	fmt.Fprintf(os.Stderr, "engine: IVF/kmeans + int16 + top5 seco + C/AVX2 bridge\n")

	s := &fasthttp.Server{
		Handler:               handler,
		MaxRequestBodySize:    32 * 1024,
		ReadBufferSize:        16 * 1024,
		WriteBufferSize:       16 * 1024,
		DisableKeepalive:      false,
		TCPKeepalive:          true,
		ReadTimeout:           0,
		WriteTimeout:          0,
		IdleTimeout:           60,
		NoDefaultServerHeader: true,
		ReduceMemoryUsage:     false,
	}

	if cfg.UseTCP {
		addr := fmt.Sprintf("%s:%d", cfg.Host, cfg.Port)
		ln, err := listenTCP(addr, cfg.ReusePort)
		if err != nil {
			log.Fatalf("listen tcp: %v", err)
		}
		fmt.Fprintf(os.Stderr, "listening TCP %s\n", addr)
		log.Fatal(s.Serve(ln))
	} else {
		if cfg.UnlinkUDS {
			os.Remove(cfg.UDSPath)
		}
		ln, err := net.Listen("unix", cfg.UDSPath)
		if err != nil {
			log.Fatalf("listen uds: %v", err)
		}
		defer os.Remove(cfg.UDSPath)
		if cfg.UDSMode > 0 {
			mode := octalFromDecimal(cfg.UDSMode)
			os.Chmod(cfg.UDSPath, os.FileMode(mode))
		}
		fmt.Fprintf(os.Stderr, "listening UDS %s mode=%d\n", cfg.UDSPath, cfg.UDSMode)
		log.Fatal(s.Serve(ln))
	}
}

func handler(ctx *fasthttp.RequestCtx) {
	switch string(ctx.Path()) {
	case "/ready":
		ctx.SetStatusCode(200)
		ctx.Response.SetBodyRaw(httpresp.Ready)
		return
	case "/fraud-score":
		if !ctx.IsPost() {
			ctx.SetStatusCode(404)
			ctx.Response.SetBodyRaw(httpresp.NotFound)
			ctx.SetConnectionClose()
			return
		}
		body := ctx.PostBody()
		if len(body) == 0 {
			ctx.SetStatusCode(400)
			ctx.SetContentType("application/json")
			ctx.Response.SetBodyRaw(httpresp.BadRequest)
			ctx.SetConnectionClose()
			return
		}
		q, ok := vectorizer.Build(body, cfg, mccTable)
		if !ok {
			ctx.SetStatusCode(400)
			ctx.SetContentType("application/json")
			ctx.Response.SetBodyRaw(httpresp.BadRequest)
			ctx.SetConnectionClose()
			return
		}
		votes := ivfsearch.BridgeSearch(q)
		if votes < 0 || votes > 5 {
			ctx.SetStatusCode(500)
			ctx.Response.SetBodyRaw(httpresp.InternalError)
			ctx.SetConnectionClose()
			return
		}
		ctx.SetStatusCode(200)
		ctx.SetContentType("application/json")
		ctx.Response.SetBodyRaw(httpresp.Score[votes])
		return
	default:
		ctx.SetStatusCode(404)
		ctx.Response.SetBodyRaw(httpresp.NotFound)
		ctx.SetConnectionClose()
	}
}

func octalFromDecimal(mode int) int {
	a := mode / 100
	b := (mode / 10) % 10
	c := mode % 10
	return (a << 6) | (b << 3) | c
}

func listenTCP(addr string, reusePort bool) (net.Listener, error) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	if cfg.TCPNoDelay {
		return &tcpNoDelayListener{TCPListener: ln.(*net.TCPListener)}, nil
	}
	return ln, nil
}

type tcpNoDelayListener struct {
	*net.TCPListener
}

func (ln *tcpNoDelayListener) Accept() (net.Conn, error) {
	c, err := ln.TCPListener.Accept()
	if err != nil {
		return nil, err
	}
	if tc, ok := c.(*net.TCPConn); ok {
		tc.SetNoDelay(true)
	}
	return c, nil
}
