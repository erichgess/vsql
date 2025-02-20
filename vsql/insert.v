// insert.v contains the implementation for the INSERT statement.

module vsql

import time

fn execute_insert(mut c Connection, stmt InsertStmt, params map[string]Value, elapsed_parse time.Duration) ?Result {
	t := start_timer()

	c.open_write_connection() ?
	defer {
		c.release_write_connection()
	}

	if stmt.columns.len < stmt.values.len {
		return sqlstate_42601('INSERT has more values than columns')
	}

	if stmt.columns.len > stmt.values.len {
		return sqlstate_42601('INSERT has less values than columns')
	}

	mut row := map[string]Value{}

	table_name := identifier_name(stmt.table_name)
	if table_name !in c.storage.tables {
		return sqlstate_42p01(table_name) // table not found
	}

	table := c.storage.tables[table_name]
	for i, column in stmt.columns {
		column_name := identifier_name(column.name)
		table_column := table.column(column_name) ?
		raw_value := eval_as_value(c, Row{}, stmt.values[i], params) ?
		value := cast('for column $column_name', raw_value, table_column.typ) ?

		if value.typ.typ == .is_null && table_column.not_null {
			return sqlstate_23502('column $column_name')
		}

		row[column_name] = value
	}

	// Fill in unspecified columns with NULL
	for col in table.columns {
		if col.name in row {
			continue
		}

		if col.not_null {
			return sqlstate_23502('column $col.name')
		}

		row[col.name] = new_null_value()
	}

	c.storage.write_row(mut new_row(row), table) ?

	return new_result_msg('INSERT 1', elapsed_parse, t.elapsed())
}
