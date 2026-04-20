#+build !freestanding
package enactod_impl

import "../pkgs/ojson"
import "core:testing"

@(private = "file")
validate_json :: proc(
	schema: ^Compiled_Schema,
	args_json: string,
) -> (
	ok: bool,
	errors: [dynamic]Schema_Error,
) {
	r: ojson.Reader
	ojson.init_reader(&r, max(len(args_json) * 4, 4096), context.temp_allocator)
	defer ojson.destroy_reader(&r)

	if ojson.parse(&r, transmute([]byte)args_json) != .OK {
		return false, nil
	}
	root := ojson.root_element(&r)
	errs, valid := validate_args(&r, root, schema)
	return valid, errs
}

@(test)
test_compile_empty_string_is_invalid :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema("")
	testing.expect(t, !schema.valid)
}

@(test)
test_compile_malformed_json_is_invalid :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(`{"type": "object" missing_brace`)
	testing.expect(t, !schema.valid)
}

@(test)
test_compile_unknown_type_is_invalid :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(`{"type": "decimal"}`)
	testing.expect(t, !schema.valid)
}

@(test)
test_compile_missing_type_is_invalid :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(`{"properties": {}}`)
	testing.expect(t, !schema.valid)
}

@(test)
test_compile_object_with_properties_and_required :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(
		`{
		"type": "object",
		"properties": {
			"name": {"type": "string"},
			"age":  {"type": "integer"}
		},
		"required": ["name"]
	}`,
	)
	testing.expect(t, schema.valid)
	testing.expect_value(t, schema.root.type, Schema_Type.OBJECT)
	testing.expect_value(t, len(schema.root.properties), 2)
	testing.expect_value(t, len(schema.root.required), 1)
	testing.expect_value(t, schema.root.required[0], "name")
}

@(test)
test_compile_additional_properties_false_flag :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(
		`{
		"type": "object",
		"properties": {"x": {"type": "string"}},
		"additionalProperties": false
	}`,
	)
	testing.expect(t, schema.valid)
	testing.expect(t, !schema.root.additional_properties)
}

@(test)
test_compile_array_with_items :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(`{
		"type": "array",
		"items": {"type": "number"}
	}`)
	testing.expect(t, schema.valid)
	testing.expect_value(t, schema.root.type, Schema_Type.ARRAY)
	testing.expect(t, schema.root.items != nil)
	testing.expect_value(t, schema.root.items.type, Schema_Type.NUMBER)
}

@(test)
test_compile_enum_values :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(`{
		"type": "string",
		"enum": ["low", "med", "high"]
	}`)
	testing.expect(t, schema.valid)
	testing.expect_value(t, len(schema.root.enum_values), 3)
	testing.expect_value(t, schema.root.enum_values[0], "low")
	testing.expect_value(t, schema.root.enum_values[2], "high")
}

@(test)
test_compile_any_of_variants :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(`{
		"anyOf": [
			{"type": "string"},
			{"type": "integer"}
		]
	}`)
	testing.expect(t, schema.valid)
	testing.expect_value(t, schema.root.type, Schema_Type.ANY_OF)
	testing.expect_value(t, len(schema.root.any_of), 2)
	testing.expect_value(t, schema.root.any_of[0].type, Schema_Type.STRING)
	testing.expect_value(t, schema.root.any_of[1].type, Schema_Type.INTEGER)
}

@(test)
test_compile_any_of_empty_array_is_invalid :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(`{"anyOf": []}`)
	testing.expect(t, !schema.valid)
}

@(test)
test_compile_every_scalar_type :: proc(t: ^testing.T) {
	cases := []struct {
		json: string,
		want: Schema_Type,
	} {
		{`{"type": "string"}`, .STRING},
		{`{"type": "number"}`, .NUMBER},
		{`{"type": "integer"}`, .INTEGER},
		{`{"type": "boolean"}`, .BOOLEAN},
		{`{"type": "null"}`, .NULL},
	}
	for c in cases {
		context.allocator = context.temp_allocator
		schema := compile_schema(c.json)
		testing.expectf(t, schema.valid, "%s should compile", c.json)
		testing.expect_value(t, schema.root.type, c.want)
	}
}

@(test)
test_compile_nested_object :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(
		`{
		"type": "object",
		"properties": {
			"addr": {
				"type": "object",
				"properties": {
					"city": {"type": "string"}
				},
				"required": ["city"]
			}
		}
	}`,
	)
	testing.expect(t, schema.valid)
	testing.expect_value(t, schema.root.properties[0].name, "addr")
	testing.expect_value(t, schema.root.properties[0].schema.type, Schema_Type.OBJECT)
	testing.expect_value(t, schema.root.properties[0].schema.properties[0].name, "city")
}

@(test)
test_validate_happy_object :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(
		`{
		"type": "object",
		"properties": {
			"name": {"type": "string"},
			"age":  {"type": "integer"}
		},
		"required": ["name"]
	}`,
	)
	ok, errors := validate_json(&schema, `{"name": "Jon", "age": 42}`)
	testing.expect(t, ok)
	testing.expect_value(t, len(errors), 0)
}

@(test)
test_validate_missing_required_field_errors :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(
		`{
		"type": "object",
		"properties": {"name": {"type": "string"}},
		"required": ["name"]
	}`,
	)
	ok, errors := validate_json(&schema, `{}`)
	testing.expect(t, !ok)
	testing.expect_value(t, len(errors), 1)
	testing.expect_value(t, errors[0].path, "name")
	testing.expect_value(t, errors[0].message, "required field missing")
}

@(test)
test_validate_wrong_type_errors :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(`{"type": "object"}`)
	ok, errors := validate_json(&schema, `"a string at the root"`)
	testing.expect(t, !ok)
	testing.expect_value(t, len(errors), 1)
	testing.expect_value(t, errors[0].path, "(root)")
}

@(test)
test_validate_additional_property_forbidden :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(
		`{
		"type": "object",
		"properties": {"x": {"type": "string"}},
		"additionalProperties": false
	}`,
	)
	ok, errors := validate_json(&schema, `{"x": "hi", "y": "nope"}`)
	testing.expect(t, !ok)
	testing.expect_value(t, len(errors), 1)
	testing.expect_value(t, errors[0].path, "y")
	testing.expect_value(t, errors[0].message, "additional property not allowed")
}

@(test)
test_validate_additional_property_allowed_by_default :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(`{
		"type": "object",
		"properties": {"x": {"type": "string"}}
	}`)
	ok, _ := validate_json(&schema, `{"x": "hi", "extra": 42}`)
	testing.expect(t, ok)
}

@(test)
test_validate_enum_match :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(`{"type": "string", "enum": ["low", "med", "high"]}`)
	ok, _ := validate_json(&schema, `"med"`)
	testing.expect(t, ok)
}

@(test)
test_validate_enum_mismatch_errors :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(`{"type": "string", "enum": ["low", "med", "high"]}`)
	ok, errors := validate_json(&schema, `"extreme"`)
	testing.expect(t, !ok)
	testing.expect_value(t, len(errors), 1)
	testing.expect_value(t, errors[0].path, "(root)")
}

@(test)
test_validate_array_items_typed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(`{"type": "array", "items": {"type": "integer"}}`)
	ok, errors := validate_json(&schema, `[1, 2, "three", 4]`)
	testing.expect(t, !ok)
	testing.expect_value(t, len(errors), 1)
	testing.expect_value(t, errors[0].path, "(root)[2]")
}

@(test)
test_validate_nested_error_path_is_reported :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(
		`{
		"type": "object",
		"properties": {
			"addr": {
				"type": "object",
				"properties": {"city": {"type": "string"}},
				"required": ["city"]
			}
		}
	}`,
	)
	ok, errors := validate_json(&schema, `{"addr": {}}`)
	testing.expect(t, !ok)
	testing.expect_value(t, len(errors), 1)
	testing.expect_value(t, errors[0].path, "addr.city")
}

@(test)
test_validate_any_of_matches_first_variant :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(`{
		"anyOf": [
			{"type": "string"},
			{"type": "integer"}
		]
	}`)
	ok, _ := validate_json(&schema, `"hello"`)
	testing.expect(t, ok)
}

@(test)
test_validate_any_of_matches_second_variant :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(`{"anyOf": [{"type": "string"}, {"type": "integer"}]}`)
	ok, _ := validate_json(&schema, `42`)
	testing.expect(t, ok)
}

@(test)
test_validate_any_of_no_match_errors :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(`{"anyOf": [{"type": "string"}, {"type": "integer"}]}`)
	ok, errors := validate_json(&schema, `true`)
	testing.expect(t, !ok)
	testing.expect_value(t, len(errors), 1)
}

@(test)
test_validate_bool_true_and_false_both_ok :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(`{"type": "boolean"}`)
	ok_true, _ := validate_json(&schema, `true`)
	ok_false, _ := validate_json(&schema, `false`)
	testing.expect(t, ok_true)
	testing.expect(t, ok_false)
}

@(test)
test_validate_null_ok :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	schema := compile_schema(`{"type": "null"}`)
	ok, _ := validate_json(&schema, `null`)
	testing.expect(t, ok)
}

@(test)
test_format_empty_errors_returns_empty_string :: proc(t: ^testing.T) {
	errors: [dynamic]Schema_Error
	testing.expect_value(t, format_schema_errors(errors), "")
}

@(test)
test_format_single_error_message :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	errors := make([dynamic]Schema_Error)
	append(&errors, Schema_Error{path = "name", message = "required field missing"})
	s := format_schema_errors(errors)
	testing.expect_value(t, s, "schema validation failed: required field missing at 'name'")
}

@(test)
test_format_multiple_errors_list_shape :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	errors := make([dynamic]Schema_Error)
	append(&errors, Schema_Error{path = "a", message = "bad1"})
	append(&errors, Schema_Error{path = "b", message = "bad2"})
	s := format_schema_errors(errors)
	testing.expect_value(t, s, "schema validation failed: [a: bad1] [b: bad2]")
}
