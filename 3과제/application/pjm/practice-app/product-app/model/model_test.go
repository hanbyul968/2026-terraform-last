package model

import "testing"

func TestCreateRequestValidate(t *testing.T) {
	ok := CreateRequest{
		RequestMeta: RequestMeta{RequestID: "1", UUID: "u"},
		ID:          "p1", Name: "n", Price: 1234,
	}
	if err := ok.Validate(); err != nil {
		t.Fatalf("expected ok, got %v", err)
	}
	for name, mutate := range map[string]func(*CreateRequest){
		"missing id":      func(r *CreateRequest) { r.ID = "" },
		"missing name":    func(r *CreateRequest) { r.Name = "" },
		"zero price":      func(r *CreateRequest) { r.Price = 0 },
		"negative price":  func(r *CreateRequest) { r.Price = -1 },
		"missing meta":    func(r *CreateRequest) { r.UUID = "" },
	} {
		t.Run(name, func(t *testing.T) {
			r := ok
			mutate(&r)
			if err := r.Validate(); err == nil {
				t.Fatal("expected error")
			}
		})
	}
}
