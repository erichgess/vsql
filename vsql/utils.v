// utils.v is just general helpful functions that don't fall into any specific
// category.

module vsql

// TODO(elliotchance): Make private when CLI is moved into vsql package.
pub fn pluralize(n int, word string) string {
	if n == 1 {
		return word
	}

	return '${word}s'
}

fn compare_bytes(a []byte, b []byte) int {
	// Only compare digits to the minimum length of both.
	min := if a.len < b.len { a.len } else { b.len }

	for i in 0 .. min {
		if a[i] != b[i] {
			return a[i] - b[i]
		}
	}

	// Equality probably doesn't matter for sorting, but let's check for that
	// too.
	if a.len == b.len {
		return 0
	}

	// If the shared length is the same, we treat the longer string as the
	// greater.
	return a.len - b.len
}
