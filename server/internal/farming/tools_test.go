package farming

import (
	"encoding/json"
	"testing"
)

// TestDefinitions_ValidSchema marshals every tool definition to JSON (the
// same encoding a real Messages API request would use) and asserts each one
// is a well-formed, non-empty JSON Schema: a non-empty name and description,
// an object-typed input_schema, and the expected required properties.
func TestDefinitions_ValidSchema(t *testing.T) {
	tests := []struct {
		name         string
		wantRequired []string
		wantProps    []string
	}{
		{ToolStartMap, []string{"map_id"}, []string{"map_id"}},
		{ToolSetFarmTarget, []string{"monster_id"}, []string{"monster_id"}},
		{ToolEngageBoss, []string{"monster_id", "kill_count"}, []string{"monster_id", "kill_count"}},
		{ToolVendorItems, nil, []string{"item_ids"}},
		{ToolEndSession, nil, nil},
	}

	defs := Definitions()
	if len(defs) != len(tests) {
		t.Fatalf("Definitions() returned %d tools, want %d", len(defs), len(tests))
	}

	seenNames := make(map[string]bool, len(defs))
	for i, tool := range defs {
		tt := tests[i]

		raw, err := json.Marshal(tool)
		if err != nil {
			t.Fatalf("marshal tool %d (%s): %v", i, tt.name, err)
		}
		var decoded map[string]any
		if err := json.Unmarshal(raw, &decoded); err != nil {
			t.Fatalf("tool %s did not marshal to valid JSON: %v", tt.name, err)
		}

		name, _ := decoded["name"].(string)
		if name == "" {
			t.Fatalf("tool %d: name is empty", i)
		}
		if name != tt.name {
			t.Errorf("tool %d: name = %q, want %q", i, name, tt.name)
		}
		if seenNames[name] {
			t.Errorf("tool name %q defined more than once", name)
		}
		seenNames[name] = true

		desc, _ := decoded["description"].(string)
		if desc == "" {
			t.Errorf("tool %q: description is empty", name)
		}

		schema, ok := decoded["input_schema"].(map[string]any)
		if !ok {
			t.Fatalf("tool %q: input_schema is not an object: %v", name, decoded["input_schema"])
		}
		if schema["type"] != "object" {
			t.Errorf("tool %q: input_schema.type = %v, want %q", name, schema["type"], "object")
		}

		props, _ := schema["properties"].(map[string]any)
		for _, wantProp := range tt.wantProps {
			if _, ok := props[wantProp]; !ok {
				t.Errorf("tool %q: input_schema.properties missing %q", name, wantProp)
			}
		}
		if len(tt.wantProps) == 0 && len(props) != 0 {
			t.Errorf("tool %q: expected no properties, got %v", name, props)
		}

		var gotRequired []string
		if reqAny, ok := schema["required"]; ok {
			for _, r := range reqAny.([]any) {
				gotRequired = append(gotRequired, r.(string))
			}
		}
		if !stringSlicesEqual(gotRequired, tt.wantRequired) {
			t.Errorf("tool %q: required = %v, want %v", name, gotRequired, tt.wantRequired)
		}
	}
}

func TestToolUnionParams_WrapsEveryDefinition(t *testing.T) {
	defs := Definitions()
	unions := ToolUnionParams()
	if len(unions) != len(defs) {
		t.Fatalf("ToolUnionParams() returned %d entries, want %d", len(unions), len(defs))
	}
	for i, u := range unions {
		if u.OfTool == nil {
			t.Fatalf("union %d: OfTool is nil", i)
		}
		if u.OfTool.Name != defs[i].Name {
			t.Errorf("union %d: name = %q, want %q", i, u.OfTool.Name, defs[i].Name)
		}
	}
}

func stringSlicesEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
