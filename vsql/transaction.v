// transaction.v contains the implementations for transaction statements:
// START TRANSACTION, COMMIT and ROLLBACK.

module vsql

import time

fn execute_start_transaction(mut c Connection, stmt StartTransactionStmt, elapsed_parse time.Duration) ?Result {
	t := start_timer()

	match c.storage.transaction_state {
		.not_active {
			// All good, continue below.
		}
		.active {
			return sqlstate_25001()
		}
		.aborted {
			return sqlstate_25p02()
		}
	}

	c.open_write_connection() ?
	defer {
		c.release_write_connection()
	}

	// isolation_start registers the transaction, then transaction_state ensures
	// that future calls to isolation_start for individual operations use the
	// same isolation scope (the transaction).
	c.storage.isolation_start() ?
	c.storage.transaction_state = .active

	// This would fail is a implicit or explicit transaction did not perform
	// cleanup.
	assert c.storage.transaction_pages.len == 0

	// TODO(elliotchance): Is this really needed? We should find a way to make
	//  sure implicit transactions erase this at the end of their used as well.
	c.storage.transaction_pages = map[int]bool{}

	return new_result_msg('START TRANSACTION', elapsed_parse, t.elapsed())
}

fn execute_commit(mut c Connection, stmt CommitStmt, elapsed_parse time.Duration) ?Result {
	t := start_timer()

	match c.storage.transaction_state {
		.not_active {
			return sqlstate_2d000()
		}
		.active {
			// All good, continue below.
		}
		.aborted {
			return sqlstate_25p02()
		}
	}

	c.open_write_connection() ?
	defer {
		c.release_write_connection()
	}

	for page_number, _ in c.storage.transaction_pages {
		mut page := c.storage.btree.pager.fetch_page(page_number) ?
		for obj in page.objects() {
			// Only remove the now expired records.
			if obj.xid == c.storage.transaction_id {
				page.delete(obj.key, c.storage.transaction_id)
			}
		}

		c.storage.btree.pager.store_page(page_number, page) ?
	}

	// We do the reverse of start_transation where we disable the active
	// transaction before calling isolation_end.
	c.storage.transaction_state = .not_active
	c.storage.isolation_end() ?

	// We can erase these now.
	c.storage.transaction_pages = map[int]bool{}

	return new_result_msg('COMMIT', elapsed_parse, t.elapsed())
}

fn execute_rollback(mut c Connection, stmt RollbackStmt, elapsed_parse time.Duration) ?Result {
	t := start_timer()

	match c.storage.transaction_state {
		.not_active {
			return sqlstate_2d000()
		}
		.active {
			// All good, continue below.
		}
		.aborted {
			return sqlstate_25p02()
		}
	}

	c.open_write_connection() ?
	defer {
		c.release_write_connection()
	}

	for page_number, _ in c.storage.transaction_pages {
		mut page := c.storage.btree.pager.fetch_page(page_number) ?
		for obj in page.objects() {
			// Only remove the objects created in this transaction.
			if obj.tid == c.storage.transaction_id {
				page.delete(obj.key, c.storage.transaction_id)
			}
		}

		c.storage.btree.pager.store_page(page_number, page) ?
	}

	// We do the reverse of start_transation where we disable the active
	// transaction before calling isolation_end.
	c.storage.transaction_state = .not_active
	c.storage.isolation_end() ?

	// We can erase these now.
	c.storage.transaction_pages = map[int]bool{}

	return new_result_msg('ROLLBACK', elapsed_parse, t.elapsed())
}
