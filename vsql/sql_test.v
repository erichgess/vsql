module vsql

import os

struct SQLTest {
	setup       []string
	params      map[string]Value
	file_name   string
	line_number int
	stmts       []string
	expected    string
}

fn get_tests() ?[]SQLTest {
	env_test := $env('TEST')
	mut tests := []SQLTest{}
	test_file_paths := os.walk_ext('tests', 'sql')
	for test_file_path in test_file_paths {
		if env_test != '' && !test_file_path.contains(env_test) {
			continue
		}
		lines := os.read_lines(test_file_path) ?

		mut stmts := []string{}
		mut expected := []string{}
		mut setup := []string{}
		mut line_number := 0
		mut stmt := ''
		mut setup_stmt := ''
		mut in_setup := false
		mut params := map[string]Value{}
		for line in lines {
			if line == '' {
				tests << SQLTest{setup, params, test_file_path, line_number, stmts, expected.join('\n')}
				stmts = []
				expected = []
				in_setup = false
				params = map[string]Value{}
			} else if line.starts_with('/*') {
				contents := line[2..line.len - 2].trim_space()
				if contents == 'setup' {
					in_setup = true
				} else if contents.starts_with('connection ') {
					stmts << contents
				} else if contents.starts_with('set ') {
					parts := contents.split(' ')
					if parts[2].starts_with("'") {
						params[parts[1]] = new_varchar_value(parts[2][1..parts[2].len - 1],
							0)
					} else {
						params[parts[1]] = new_double_precision_value(parts[2].f64())
					}
				} else {
					panic('bad directive: "$contents"')
				}
			} else if line.starts_with('-- ') {
				expected << line[3..]
			} else {
				if in_setup {
					setup_stmt += '\n$line'
					if line.ends_with(';') {
						setup << setup_stmt
						setup_stmt = ''
					}
				} else {
					stmt += '\n$line'
					if line.ends_with(';') {
						stmts << stmt
						stmt = ''
					}
				}
			}

			line_number++
		}

		if stmts.len > 0 {
			tests << SQLTest{setup, params, test_file_path, line_number, stmts, expected.join('\n')}
		}
	}

	return tests
}

fn test_all() ? {
	verbose := $env('VERBOSE')
	query_cache := new_query_cache()
	for test in get_tests() ? {
		run_single_test(test, query_cache, verbose != '') ?
	}
}

fn run_single_test(test SQLTest, query_cache &QueryCache, verbose bool) ? {
	if verbose {
		println('BEGIN $test.file_name:$test.line_number')
		defer {
			println('END $test.file_name:$test.line_number\n')
		}
	}

	mut options := default_connection_options()
	options.query_cache = query_cache

	mut db := open_database(':memory:', options) ?
	register_pg_functions(mut db) ?

	// If a test needs multiple connections we cannot rely on ":memory:".
	// The default connection is called "main". The docs explain that "main"
	// should not be referenced in tests and the "connection" directive must
	// be the first line in the test.
	mut connections := map[string]&Connection{}
	mut current_connection_name := ''

	file_name := 'test.vsql'
	if os.exists(file_name) {
		os.rm(file_name) ?
	}

	for stmt in test.setup {
		if verbose {
			println('  $stmt.trim_space()')
		}

		mut prepared := db.prepare(stmt) ?
		prepared.query(test.params) ?
	}

	mut actual := ''
	for stmt in test.stmts {
		if stmt.starts_with('connection ') {
			connection_name := stmt[11..]
			if connection_name !in connections {
				mut conn := open_database(file_name, options) ?
				register_pg_functions(mut conn) ?
				connections[connection_name] = conn
			}

			db = connections[connection_name]
			current_connection_name = connection_name
			continue
		}

		if verbose {
			println('  $stmt.trim_space()')
		}

		mut prepared := db.prepare(stmt) or {
			actual += 'error ${sqlstate_from_int(err.code)}: $err.msg\n'
			continue
		}
		result := prepared.query(test.params) or {
			if current_connection_name == '' {
				actual += 'error ${sqlstate_from_int(err.code)}: $err.msg\n'
			} else {
				actual += '$current_connection_name: error ${sqlstate_from_int(err.code)}: $err.msg\n'
			}

			continue
		}

		for row in result {
			mut line := ''

			if current_connection_name != '' {
				line = '$current_connection_name: '
			}

			for col in result.columns {
				line += '$col: ${row.get_string(col) ?} '
			}
			actual += line.trim_space() + '\n'
		}
	}

	at := 'at $test.file_name:$test.line_number:\n'
	expected := at + test.expected.trim_space()
	actual_trim := at + actual.trim_space()
	assert expected == actual_trim
}
