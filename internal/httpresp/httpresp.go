package httpresp

// Pre-computed response bodies.
// ScoreBody indexed by fraud count (0-5) for zero-overhead response.
var (
	ScoreBody     [6][]byte
	Ready         = []byte{}
	NotFound      = []byte{}
	BadRequest    = []byte(`{"error":"invalid_payload"}`)
	InternalError = []byte{}
)

func Init() {
	ScoreBody[0] = []byte(`{"approved":true,"fraud_score":0.0000}`)
	ScoreBody[1] = []byte(`{"approved":true,"fraud_score":0.2000}`)
	ScoreBody[2] = []byte(`{"approved":true,"fraud_score":0.4000}`)
	ScoreBody[3] = []byte(`{"approved":false,"fraud_score":0.6000}`)
	ScoreBody[4] = []byte(`{"approved":false,"fraud_score":0.8000}`)
	ScoreBody[5] = []byte(`{"approved":false,"fraud_score":1.0000}`)
}
