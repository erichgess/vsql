// pager.v contains the interface and implementation for a pager that stores
// pages in memory or on disk.
//
// A new pager is created for each operation on the file. See btree.v.
//
// See https://github.com/elliotchance/vsql/issues/45.

module vsql

import os

interface Pager {
mut:
	fetch_page(page_number int) ?Page
	store_page(page_number int, page Page) ?
	append_page(page Page) ?
	truncate_all() ?
	truncate_last_page() ?
	total_pages() int
	root_page() int
	set_root_page(page_number int) ?
}

struct MemoryPager {
mut:
	// root_page is the starting page for a traversal. The root page may change
	// as balancing happens on the tree.
	root_page int
	pages     []Page
}

fn new_memory_pager() &MemoryPager {
	return &MemoryPager{}
}

fn (mut p MemoryPager) fetch_page(page_number int) ?Page {
	return p.pages[page_number]
}

fn (mut p MemoryPager) store_page(page_number int, page Page) ? {
	p.pages[page_number] = page
}

fn (mut p MemoryPager) total_pages() int {
	return p.pages.len
}

fn (mut p MemoryPager) append_page(page Page) ? {
	p.pages << page
}

fn (mut p MemoryPager) truncate_all() ? {
	p.pages = []Page{}
}

fn (mut p MemoryPager) truncate_last_page() ? {
	p.pages = p.pages[..p.pages.len - 1]
}

fn (mut p MemoryPager) root_page() int {
	return p.root_page
}

fn (mut p MemoryPager) set_root_page(page_number int) ? {
	p.root_page = page_number
}

struct FilePager {
	page_size int
mut:
	file        os.File
	total_pages int
	// root_page is the starting page for a traversal. The root page may change
	// as balancing happens on the tree.
	root_page int
}

// new_file_pager requires that the path already exists and has already been
// initialized as a new database.
fn new_file_pager(mut file os.File, page_size int, root_page int) ?&FilePager {
	file.seek(0, .end) ?
	file_len := file.tell() ?

	return &FilePager{
		file: file
		page_size: page_size
		root_page: root_page
		// The first page is reserved for header information. We do not include
		// this in the pages.
		total_pages: int((file_len - sizeof(Header)) / i64(page_size))
	}
}

fn (mut p FilePager) fetch_page(page_number int) ?Page {
	// The first page is reserved for header information. We do not include this
	// in the pages.
	p.file.seek(int(sizeof(Header)) + (p.page_size * page_number), .start) ?

	mut buf := []byte{len: p.page_size}
	p.file.read(mut buf) ?

	mut b := new_bytes(buf)

	return Page{
		kind: b.read_byte()
		used: b.read_u16()
		data: buf[3..]
	}
}

fn (mut p FilePager) store_page(page_number int, page Page) ? {
	// The first page is reserved for header information. We do not include this
	// in the pages.
	p.file.seek(int(sizeof(Header)) + (p.page_size * page_number), .start) ?

	mut b := new_bytes([]byte{})
	b.write_byte(page.kind)
	b.write_u16(page.used)
	b.write_bytes(page.data)

	p.file.write(b.bytes()) ?
}

fn (mut p FilePager) total_pages() int {
	return p.total_pages
}

fn (mut p FilePager) append_page(page Page) ? {
	// The first page is reserved for header information. We do not include this
	// in the pages.
	p.store_page(p.total_pages, page) ?
	p.total_pages++
}

fn (mut p FilePager) truncate_all() ? {
	p.total_pages = 0
}

fn (mut p FilePager) truncate_last_page() ? {
	p.total_pages--
}

fn (mut p FilePager) root_page() int {
	return p.root_page
}

fn (mut p FilePager) set_root_page(page_number int) ? {
	p.root_page = page_number
}
