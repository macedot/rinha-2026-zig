package vectorizer

import (
	"rinha-2026/internal/config"
	"rinha-2026/internal/jsonparse"
	"rinha-2026/internal/mccrisk"
)

func clamp01(x float32) float32 {
	if x < 0 {
		return 0
	}
	if x > 1 {
		return 1
	}
	return x
}

func isoYear(s []byte) int {
	return int(s[0]-'0')*1000 + int(s[1]-'0')*100 + int(s[2]-'0')*10 + int(s[3]-'0')
}
func isoMonth(s []byte) int  { return int(s[5]-'0')*10 + int(s[6]-'0') }
func isoDay(s []byte) int    { return int(s[8]-'0')*10 + int(s[9]-'0') }
func isoHourUTC(s []byte) int {
	h := int(s[11]-'0')*10 + int(s[12]-'0')
	if h < 0 {
		return 0
	}
	if h > 23 {
		return 23
	}
	return h
}
func isoMinute(s []byte) int { return int(s[14]-'0')*10 + int(s[15]-'0') }
func isoSecond(s []byte) int { return int(s[17]-'0')*10 + int(s[18]-'0') }

func daysFromCivil(y int, m uint, d uint) int64 {
	if m <= 2 {
		y--
	}
	var era int
	if y >= 0 {
		era = y / 400
	} else {
		era = (y - 399) / 400
	}
	yoe := uint(y - era*400)
	var doy uint
	if m > 2 {
		doy = (153*(m-3) + 2) / 5 + d - 1
	} else {
		doy = (153*(m+9) + 2) / 5 + d - 1
	}
	doe := yoe*365 + yoe/4 - yoe/100 + doy
	return int64(era)*146097 + int64(doe) - 719468
}

func weekdayFromISO(s []byte) int {
	days := daysFromCivil(isoYear(s), uint(isoMonth(s)), uint(isoDay(s)))
	w := int((days + 3) % 7)
	if w < 0 {
		w += 7
	}
	return w
}

func isoToEpochSeconds(s []byte) int64 {
	days := daysFromCivil(isoYear(s), uint(isoMonth(s)), uint(isoDay(s)))
	return days*86400 + int64(isoHourUTC(s))*3600 + int64(isoMinute(s))*60 + int64(isoSecond(s))
}

func minutesBetweenAbs(a, b []byte) int64 {
	diff := isoToEpochSeconds(a) - isoToEpochSeconds(b)
	if diff < 0 {
		diff = -diff
	}
	return diff / 60
}

func Build(body []byte, cfg *config.Config, mccTable *mccrisk.Table) ([14]float32, bool) {
	var q [14]float32

	transaction, ok := jsonparse.ObjectRange(body, "transaction")
	if !ok {
		return q, false
	}
	customer, ok := jsonparse.ObjectRange(body, "customer")
	if !ok {
		return q, false
	}
	merchant, ok := jsonparse.ObjectRange(body, "merchant")
	if !ok {
		return q, false
	}
	terminal, ok := jsonparse.ObjectRange(body, "terminal")
	if !ok {
		return q, false
	}

	amount, ok1 := jsonparse.JSONNumber(transaction, "amount")
	installments, ok2 := jsonparse.JSONNumber(transaction, "installments")
	var requestedAtBuf [40]byte
	requestedAt, ok3 := jsonparse.JSONString(transaction, "requested_at", requestedAtBuf[:])
	if !ok1 || !ok2 || !ok3 {
		return q, false
	}

	customerAvgAmount, ok4 := jsonparse.JSONNumber(customer, "avg_amount")
	txCount24h, ok5 := jsonparse.JSONNumber(customer, "tx_count_24h")
	if !ok4 || !ok5 {
		return q, false
	}

	var merchantIDBuf [64]byte
	merchantID, ok6 := jsonparse.JSONString(merchant, "id", merchantIDBuf[:])
	var mccBuf [16]byte
	mcc, ok7 := jsonparse.JSONString(merchant, "mcc", mccBuf[:])
	merchantAvgAmount, ok8 := jsonparse.JSONNumber(merchant, "avg_amount")
	if !ok6 || !ok7 || !ok8 {
		return q, false
	}

	isOnline, ok9 := jsonparse.JSONBool(terminal, "is_online")
	cardPresent, ok10 := jsonparse.JSONBool(terminal, "card_present")
	kmFromHome, ok11 := jsonparse.JSONNumber(terminal, "km_from_home")
	if !ok9 || !ok10 || !ok11 {
		return q, false
	}

	minutesSinceLastTx := float32(-1.0)
	kmFromLastTx := float32(-1.0)

	ltObj, ok := jsonparse.ObjectRange(body, "last_transaction")
	if ok {
		var lastTsBuf [40]byte
		lastTs, ok1 := jsonparse.JSONString(ltObj, "timestamp", lastTsBuf[:])
		kmFromCurrent, ok2 := jsonparse.JSONNumber(ltObj, "km_from_current")
		if ok1 && ok2 {
			mins := minutesBetweenAbs(requestedAt, lastTs)
			minutesSinceLastTx = clamp01(float32(mins) / 1440.0)
			kmFromLastTx = clamp01(kmFromCurrent / cfg.KmDivisor)
		}
	}

	knownMerchant := jsonparse.ArrayContainsString(customer, "known_merchants", merchantID)
	unknownMerchant := float32(1.0)
	if knownMerchant {
		unknownMerchant = 0.0
	}

	amountVsAvg := float32(1.0)
	if customerAvgAmount > 0 {
		amountVsAvg = clamp01((amount/customerAvgAmount)/10.0)
	}

	q[0] = clamp01(amount / cfg.AmountDivisor)
	q[1] = clamp01(installments / cfg.InstallmentsDivisor)
	q[2] = amountVsAvg
	q[3] = clamp01(float32(isoHourUTC(requestedAt)) / 23.0)
	q[4] = clamp01(float32(weekdayFromISO(requestedAt)) / 6.0)
	q[5] = minutesSinceLastTx
	q[6] = kmFromLastTx
	q[7] = clamp01(kmFromHome / cfg.KmDivisor)
	q[8] = clamp01(txCount24h / cfg.Tx24hDivisor)
	if isOnline == 1 {
		q[9] = 1.0
	} else {
		q[9] = 0.0
	}
	if cardPresent == 1 {
		q[10] = 1.0
	} else {
		q[10] = 0.0
	}
	q[11] = unknownMerchant
	q[12] = mccTable.GetBytes(mcc)
	q[13] = clamp01(merchantAvgAmount / cfg.MerchantAmountDivisor)

	return q, true
}
