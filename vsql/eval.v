// eval.v executes expressions (such as you would find in a WHERE condition).

module vsql

fn eval_row(conn &Connection, data Row, exprs []Expr, params map[string]Value) ?Row {
	mut col_number := 1
	mut row := map[string]Value{}
	for expr in exprs {
		row['COL$col_number'] = eval_as_value(conn, data, expr, params) ?
		col_number++
	}

	return Row{
		data: row
	}
}

fn eval_as_value(conn &Connection, data Row, e Expr, params map[string]Value) ?Value {
	match e {
		BetweenExpr {
			return eval_between(conn, data, e, params)
		}
		BinaryExpr {
			return eval_binary(conn, data, e, params)
		}
		CallExpr {
			return eval_call(conn, data, e, params)
		}
		Identifier {
			return eval_identifier(data, e)
		}
		NullExpr {
			return eval_null(conn, data, e, params)
		}
		Parameter {
			return params[e.name] or { return sqlstate_42p02(e.name) }
		}
		UnaryExpr {
			return eval_unary(conn, data, e, params)
		}
		Value {
			return e
		}
		NoExpr, RowExpr {
			// RowExpr should never make it to eval because it will be
			// reformatted into a ValuesOperation.
			return sqlstate_42601('missing or invalid expression provided')
		}
	}
}

fn eval_as_bool(conn &Connection, data Row, e Expr, params map[string]Value) ?bool {
	v := eval_as_value(conn, data, e, params) ?

	if v.typ.typ == .is_boolean {
		return v.f64_value != 0
	}

	return sqlstate_42804('in expression', 'BOOLEAN', v.typ.str())
}

fn eval_identifier(data Row, e Identifier) ?Value {
	col := identifier_name(e.name)
	value := data.data[col] or { return sqlstate_42601(col) }

	return value
}

fn eval_call(conn &Connection, data Row, e CallExpr, params map[string]Value) ?Value {
	func_name := identifier_name(e.function_name)

	func := conn.funcs[func_name] or {
		// function does not exist
		return sqlstate_42883(func_name)
	}

	if e.args.len != func.arg_types.len {
		return sqlstate_42883('$func_name has $e.args.len ${pluralize(e.args.len, 'argument')} but needs $func.arg_types.len ${pluralize(func.arg_types.len,
			'argument')}')
	}

	mut args := []Value{}
	mut i := 0
	for typ in func.arg_types {
		arg := eval_as_value(conn, data, e.args[i], params) ?
		args << cast('argument ${i + 1} in $func_name', arg, typ) ?
		i++
	}

	return func.func(args)
}

fn eval_null(conn &Connection, data Row, e NullExpr, params map[string]Value) ?Value {
	value := eval_as_value(conn, data, e.expr, params) ?

	if e.not {
		return new_boolean_value(value.typ.typ != .is_null)
	}

	return new_boolean_value(value.typ.typ == .is_null)
}

fn eval_binary(conn &Connection, data Row, e BinaryExpr, params map[string]Value) ?Value {
	left := eval_as_value(conn, data, e.left, params) ?
	right := eval_as_value(conn, data, e.right, params) ?

	match e.op {
		'=', '<>', '>', '<', '>=', '<=' {
			if left.typ.uses_f64() && right.typ.uses_f64() {
				return eval_cmp<f64>(left.f64_value, right.f64_value, e.op)
			}

			if left.typ.uses_string() && right.typ.uses_string() {
				return eval_cmp<string>(left.string_value, right.string_value, e.op)
			}
		}
		'||' {
			if left.typ.uses_string() && right.typ.uses_string() {
				return new_varchar_value(left.string_value + right.string_value, 0)
			}
		}
		'+' {
			if left.typ.uses_f64() && right.typ.uses_f64() {
				return new_double_precision_value(left.f64_value + right.f64_value)
			}
		}
		'-' {
			if left.typ.uses_f64() && right.typ.uses_f64() {
				return new_double_precision_value(left.f64_value - right.f64_value)
			}
		}
		'*' {
			if left.typ.uses_f64() && right.typ.uses_f64() {
				return new_double_precision_value(left.f64_value * right.f64_value)
			}
		}
		'/' {
			if left.typ.uses_f64() && right.typ.uses_f64() {
				if right.f64_value == 0 {
					return sqlstate_22012() // division by zero
				}

				return new_double_precision_value(left.f64_value / right.f64_value)
			}
		}
		'AND' {
			if left.typ.typ == .is_boolean && right.typ.typ == .is_boolean {
				return new_boolean_value((left.f64_value != 0) && (right.f64_value != 0))
			}
		}
		'OR' {
			if left.typ.typ == .is_boolean && right.typ.typ == .is_boolean {
				return new_boolean_value((left.f64_value != 0) || (right.f64_value != 0))
			}
		}
		else {}
	}

	return sqlstate_42804('cannot $left.typ $e.op $right.typ', 'another type', '$left.typ and $right.typ')
}

fn eval_unary(conn &Connection, data Row, e UnaryExpr, params map[string]Value) ?Value {
	value := eval_as_value(conn, data, e.expr, params) ?

	match e.op {
		'-' {
			if value.typ.uses_f64() {
				return new_double_precision_value(-value.f64_value)
			}
		}
		'+' {
			if value.typ.uses_f64() {
				return new_double_precision_value(value.f64_value)
			}
		}
		'NOT' {
			if value.typ.typ == .is_boolean {
				return new_boolean_value(!(value.f64_value != 0))
			}
		}
		else {}
	}

	return sqlstate_42804('cannot $e.op$value.typ', 'another type', value.typ.str())
}

fn eval_cmp<T>(lhs T, rhs T, op string) Value {
	return new_boolean_value(match op {
		'=' { lhs == rhs }
		'<>' { lhs != rhs }
		'>' { lhs > rhs }
		'>=' { lhs >= rhs }
		'<' { lhs < rhs }
		'<=' { lhs <= rhs }
		// This should not be possible because the parser has already verified
		// this.
		else { false }
	})
}

fn eval_between(conn &Connection, data Row, e BetweenExpr, params map[string]Value) ?Value {
	expr := eval_as_value(conn, data, e.expr, params) ?
	mut left := eval_as_value(conn, data, e.left, params) ?
	mut right := eval_as_value(conn, data, e.right, params) ?

	// SYMMETRIC operandsmight need to be swapped.
	cmp, is_null := left.cmp(right) ?
	if e.symmetric && !is_null && cmp > 0 {
		left, right = right, left
	}

	lower, lower_is_null := expr.cmp(left) ?
	upper, upper_is_null := expr.cmp(right) ?

	if lower_is_null || upper_is_null {
		return new_null_value()
	}

	mut result := lower >= 0 && upper <= 0

	if e.not {
		result = !result
	}

	return new_boolean_value(result)
}
