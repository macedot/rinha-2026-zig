package httpresp

import "fmt"

var (
	Score         [6][]byte
	Ready         []byte
	NotFound      []byte
	BadRequest    []byte
	TooLarge      []byte
	InternalError []byte
)

func Init() {
	for frauds := 0; frauds <= 5; frauds++ {
		score := float32(frauds) * 0.2
		approved := "true"
		if frauds >= 3 {
			approved = "false"
		}
		Score[frauds] = []byte(fmt.Sprintf(`{"approved":%s,"fraud_score":%.4f}`, approved, score))
	}
	Ready = []byte{}
	NotFound = []byte{}
	BadRequest = []byte(`{"error":"invalid_payload"}`)
	TooLarge = []byte{}
	InternalError = []byte{}
}
