package config

import (
	"os"
	"strconv"
)

type Config struct {
	IndexPath             string
	MccRiskPath           string
	IvfNprobe             int
	IvfFullNprobe         int
	Candidates            int
	UseTCP                bool
	Port                  int
	Host                  string
	UDSPath               string
	UDSMode               int
	UnlinkUDS             bool
	TCPNoDelay            bool
	ReusePort             bool
	AmountDivisor         float32
	InstallmentsDivisor   float32
	Tx24hDivisor          float32
	KmDivisor             float32
	MerchantAmountDivisor float32
}

func Load() *Config {
	return &Config{
		IndexPath:             envStr("INDEX_PATH", "resources/index.bin"),
		MccRiskPath:           envStr("MCC_RISK_PATH", "resources/mcc_risk.json"),
		IvfNprobe:             envInt("IVF_NPROBE", 32, 1, 512),
		IvfFullNprobe:         envInt("IVF_FULL_NPROBE", 8, 1, 512),
		Candidates:            envInt("CANDIDATES", 0, 0, 2000000),
		UseTCP:                envInt("LISTEN_TCP", 0, 0, 1) == 1,
		Port:                  envInt("PORT", 9999, 1, 65535),
		Host:                  envStr("HOST", "0.0.0.0"),
		UDSPath:               envStr("UDS_PATH", envStr("SOCKET_PATH", "/tmp/rinha.sock")),
		UDSMode:               envInt("UDS_MODE", 666, 0, 777),
		UnlinkUDS:             envInt("UNLINK_UDS", 1, 0, 1) == 1,
		TCPNoDelay:            envInt("TCP_NODELAY", 1, 0, 1) == 1,
		ReusePort:             envInt("SO_REUSEPORT_ENABLED", 1, 0, 1) == 1,
		AmountDivisor:         envFloat("AMOUNT_DIVISOR", 10000.0, 1.0, 100000000.0),
		InstallmentsDivisor:   envFloat("INSTALLMENTS_DIVISOR", 12.0, 1.0, 1000.0),
		Tx24hDivisor:          envFloat("TX24H_DIVISOR", 20.0, 1.0, 100000.0),
		KmDivisor:             envFloat("KM_DIVISOR", 1000.0, 1.0, 10000000.0),
		MerchantAmountDivisor: envFloat("MERCHANT_AMOUNT_DIVISOR", 10000.0, 1.0, 100000000.0),
	}
}

func envStr(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

func envInt(name string, def, minv, maxv int) int {
	v, err := strconv.Atoi(os.Getenv(name))
	if err != nil {
		return def
	}
	if v < minv {
		return minv
	}
	if v > maxv {
		return maxv
	}
	return v
}

func envFloat(name string, def, minv, maxv float32) float32 {
	f, err := strconv.ParseFloat(os.Getenv(name), 32)
	if err != nil {
		return def
	}
	v := float32(f)
	if v < minv {
		return minv
	}
	if v > maxv {
		return maxv
	}
	return v
}
