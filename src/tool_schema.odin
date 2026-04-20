package enactod_impl

import "../pkgs/ojson"
import "core:fmt"
import "core:log"
import "core:strings"

Schema_Type :: enum u8 {
	OBJECT,
	ARRAY,
	STRING,
	NUMBER,
	INTEGER,
	BOOLEAN,
	NULL,
	ANY_OF,
}

Schema_Node :: struct {
	type:                  Schema_Type,
	properties:            []Schema_Property,
	required:              []string,
	additional_properties: bool,
	items:                 ^Schema_Node,
	enum_values:           []string,
	any_of:                []Schema_Node,
}

Schema_Property :: struct {
	name:   string,
	schema: Schema_Node,
}

Compiled_Schema :: struct {
	root:  Schema_Node,
	valid: bool,
}

Schema_Error :: struct {
	path:    string,
	message: string,
}

compile_schema :: proc(raw_json: string) -> Compiled_Schema {
	if len(raw_json) == 0 {
		return {}
	}

	r: ojson.Reader
	ojson.init_reader(&r, max(len(raw_json) * 4, 4096), context.temp_allocator)
	defer ojson.destroy_reader(&r)

	if ojson.parse(&r, transmute([]byte)raw_json) != .OK {
		log.warnf("schema: failed to parse input_schema JSON")
		return {}
	}

	root := ojson.root_element(&r)
	node, ok := compile_node(&r, root)
	if !ok {
		return {}
	}
	return Compiled_Schema{root = node, valid = true}
}

@(private)
compile_node :: proc(r: ^ojson.Reader, elem: ojson.Element) -> (Schema_Node, bool) {
	any_of_elem, any_of_err := ojson.obj_element_from(r, elem, "anyOf")
	if any_of_err == .OK {
		items, arr_err := ojson.array_elements_from(r, any_of_elem)
		if arr_err != .OK || len(items) == 0 {
			return {}, false
		}
		variants := make([]Schema_Node, len(items))
		for item, i in items {
			node, ok := compile_node(r, item)
			if !ok {
				return {}, false
			}
			variants[i] = node
		}
		return Schema_Node{type = .ANY_OF, any_of = variants, additional_properties = true}, true
	}

	type_str, type_err := ojson.read_string_elem(r, elem, "type")
	if type_err != .OK {
		return {}, false
	}

	node: Schema_Node
	node.additional_properties = true

	switch type_str {
	case "object":
		node.type = .OBJECT
	case "array":
		node.type = .ARRAY
	case "string":
		node.type = .STRING
	case "number":
		node.type = .NUMBER
	case "integer":
		node.type = .INTEGER
	case "boolean":
		node.type = .BOOLEAN
	case "null":
		node.type = .NULL
	case:
		return {}, false
	}

	if node.type == .OBJECT {
		props_elem, props_err := ojson.obj_element_from(r, elem, "properties")
		if props_err == .OK {
			keys := ojson.object_keys(r, props_elem)
			if len(keys) > 0 {
				node.properties = make([]Schema_Property, len(keys))
				for key, i in keys {
					prop_elem, prop_err := ojson.obj_element_from(r, props_elem, key)
					if prop_err != .OK {
						return {}, false
					}
					prop_node, ok := compile_node(r, prop_elem)
					if !ok {
						return {}, false
					}
					node.properties[i] = Schema_Property {
						name   = strings.clone(key),
						schema = prop_node,
					}
				}
			}
		}

		req_elem, req_err := ojson.obj_element_from(r, elem, "required")
		if req_err == .OK {
			req_items, arr_err := ojson.array_elements_from(r, req_elem)
			if arr_err == .OK && len(req_items) > 0 {
				node.required = make([]string, len(req_items))
				for item, i in req_items {
					s, s_err := ojson.read_string_value(r, item)
					if s_err != .OK {
						return {}, false
					}
					node.required[i] = strings.clone(s)
				}
			}
		}

		ap, ap_err := ojson.read_bool_elem(r, elem, "additionalProperties")
		if ap_err == .OK {
			node.additional_properties = ap
		}
	}

	if node.type == .ARRAY {
		items_elem, items_err := ojson.obj_element_from(r, elem, "items")
		if items_err == .OK {
			items_node, ok := compile_node(r, items_elem)
			if !ok {
				return {}, false
			}
			items_ptr := new(Schema_Node)
			items_ptr^ = items_node
			node.items = items_ptr
		}
	}

	enum_elem, enum_err := ojson.obj_element_from(r, elem, "enum")
	if enum_err == .OK {
		enum_items, arr_err := ojson.array_elements_from(r, enum_elem)
		if arr_err == .OK && len(enum_items) > 0 {
			node.enum_values = make([]string, len(enum_items))
			for item, i in enum_items {
				s, s_err := ojson.read_string_value(r, item)
				if s_err == .OK {
					node.enum_values[i] = strings.clone(s)
				}
			}
		}
	}

	return node, true
}

validate_args :: proc(
	r: ^ojson.Reader,
	root: ojson.Element,
	schema: ^Compiled_Schema,
) -> (
	errors: [dynamic]Schema_Error,
	ok: bool,
) {
	errors = make([dynamic]Schema_Error, context.temp_allocator)
	validate_node(r, root, &schema.root, "", &errors)
	return errors, len(errors) == 0
}

@(private)
validate_node :: proc(
	r: ^ojson.Reader,
	elem: ojson.Element,
	node: ^Schema_Node,
	path: string,
	errors: ^[dynamic]Schema_Error,
) {
	if node.type == .ANY_OF {
		validate_any_of(r, elem, node, path, errors)
		return
	}

	vt := ojson.element_value_type(r, elem)

	if !type_matches(vt, node.type) {
		append(
			errors,
			Schema_Error {
				path = path_or_root(path),
				message = fmt.tprintf(
					"expected %s, got %s",
					schema_type_name(node.type),
					value_type_name(vt),
				),
			},
		)
		return
	}

	if len(node.enum_values) > 0 {
		validate_enum(r, elem, vt, node, path, errors)
	}

	switch node.type {
	case .OBJECT:
		validate_object(r, elem, node, path, errors)
	case .ARRAY:
		validate_array(r, elem, node, path, errors)
	case .STRING, .NUMBER, .INTEGER, .BOOLEAN, .NULL, .ANY_OF:
	}
}

@(private)
validate_object :: proc(
	r: ^ojson.Reader,
	elem: ojson.Element,
	node: ^Schema_Node,
	path: string,
	errors: ^[dynamic]Schema_Error,
) {
	for req in node.required {
		_, err := ojson.obj_element_from(r, elem, req)
		if err != .OK {
			append(
				errors,
				Schema_Error{path = join_path(path, req), message = "required field missing"},
			)
		}
	}

	for &prop in node.properties {
		prop_elem, err := ojson.obj_element_from(r, elem, prop.name)
		if err == .OK {
			validate_node(r, prop_elem, &prop.schema, join_path(path, prop.name), errors)
		}
	}

	if !node.additional_properties && len(node.properties) > 0 {
		keys := ojson.object_keys(r, elem)
		for key in keys {
			found := false
			for &prop in node.properties {
				if prop.name == key {
					found = true
					break
				}
			}
			if !found {
				append(
					errors,
					Schema_Error {
						path = join_path(path, key),
						message = "additional property not allowed",
					},
				)
			}
		}
	}
}

@(private)
validate_array :: proc(
	r: ^ojson.Reader,
	elem: ojson.Element,
	node: ^Schema_Node,
	path: string,
	errors: ^[dynamic]Schema_Error,
) {
	if node.items == nil {
		return
	}
	items, err := ojson.array_elements_from(r, elem)
	if err != .OK {
		return
	}
	for item, i in items {
		item_path := fmt.tprintf("%s[%d]", path_or_root(path), i)
		validate_node(r, item, node.items, item_path, errors)
	}
}

@(private)
validate_any_of :: proc(
	r: ^ojson.Reader,
	elem: ojson.Element,
	node: ^Schema_Node,
	path: string,
	errors: ^[dynamic]Schema_Error,
) {
	for &variant in node.any_of {
		trial := make([dynamic]Schema_Error, context.temp_allocator)
		validate_node(r, elem, &variant, path, &trial)
		if len(trial) == 0 {
			return
		}
	}
	vt := ojson.element_value_type(r, elem)
	append(
		errors,
		Schema_Error {
			path = path_or_root(path),
			message = fmt.tprintf(
				"value of type %s does not match any variant in anyOf",
				value_type_name(vt),
			),
		},
	)
}

@(private)
validate_enum :: proc(
	r: ^ojson.Reader,
	elem: ojson.Element,
	vt: ojson.Value_Type,
	node: ^Schema_Node,
	path: string,
	errors: ^[dynamic]Schema_Error,
) {
	#partial switch vt {
	case .String, .Raw_String:
		s, err := ojson.read_string_value(r, elem)
		if err != .OK {
			return
		}
		for ev in node.enum_values {
			if s == ev {
				return
			}
		}
		append(
			errors,
			Schema_Error {
				path = path_or_root(path),
				message = fmt.tprintf("value '%s' not in enum", s),
			},
		)
	case:
	// enum on non-string types: skip validation
	}
}

@(private)
type_matches :: proc(vt: ojson.Value_Type, st: Schema_Type) -> bool {
	switch st {
	case .OBJECT:
		return vt == .Object
	case .ARRAY:
		return vt == .Array
	case .STRING:
		return vt == .String || vt == .Raw_String
	case .NUMBER:
		return vt == .Number
	case .INTEGER:
		return vt == .Number
	case .BOOLEAN:
		return vt == .True || vt == .False
	case .NULL:
		return vt == .Null
	case .ANY_OF:
		return true
	}
	return false
}

@(private)
schema_type_name :: proc(st: Schema_Type) -> string {
	switch st {
	case .OBJECT:
		return "object"
	case .ARRAY:
		return "array"
	case .STRING:
		return "string"
	case .NUMBER:
		return "number"
	case .INTEGER:
		return "integer"
	case .BOOLEAN:
		return "boolean"
	case .NULL:
		return "null"
	case .ANY_OF:
		return "anyOf"
	}
	return "unknown"
}

@(private)
value_type_name :: proc(vt: ojson.Value_Type) -> string {
	switch vt {
	case .Object:
		return "object"
	case .Array:
		return "array"
	case .String, .Raw_String:
		return "string"
	case .Number:
		return "number"
	case .True, .False:
		return "boolean"
	case .Null:
		return "null"
	}
	return "unknown"
}

@(private)
join_path :: proc(base: string, field: string) -> string {
	if len(base) == 0 {
		return field
	}
	return fmt.tprintf("%s.%s", base, field)
}

@(private)
path_or_root :: proc(path: string) -> string {
	if len(path) == 0 {
		return "(root)"
	}
	return path
}

format_schema_errors :: proc(errors: [dynamic]Schema_Error) -> string {
	if len(errors) == 0 {
		return ""
	}
	if len(errors) == 1 {
		return fmt.tprintf(
			"schema validation failed: %s at '%s'",
			errors[0].message,
			errors[0].path,
		)
	}
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "schema validation failed:")
	for e in errors {
		fmt.sbprintf(&sb, " [%s: %s]", e.path, e.message)
	}
	return strings.to_string(sb)
}
