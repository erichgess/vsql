// page.v contains the operations for manipulating a single page, such as adding
// and removing objects.

module vsql

const (
	kind_leaf     = 0 // page contains only objects.
	kind_not_leaf = 1 // page contains only links to other pages.
)

// page_object_prefix_length is the precalculated length that will be the
// combination of all fixed width meta for the page object.
const page_object_prefix_length = 14

struct PageObject {
	// The key is not required to be unique in the page. It becomes unique when
	// combined with tid. However, no more than two version of the same key can
	// exist in a page. See the caveats at the top of btree.v.
	key []byte
	// The value contains the serialized data for the object. The first byte of
	// key is used to both identify what type of object this is and also keep
	// objects within the same collection also within the same range.
	value []byte
mut:
	// The tid is the transaction that created the object.
	//
	// TODO(elliotchance): It makes more sense to construct a new PageObject
	//  when changing the tid and xid.
	tid int
	// The xid is the transaciton that deleted the object, or zero if it has
	// never been deleted.
	xid int
}

fn new_page_object(key []byte, tid int, xid int, value []byte) PageObject {
	return PageObject{key, value, tid, xid}
}

fn (o PageObject) length() int {
	return vsql.page_object_prefix_length + o.key.len + o.value.len
}

// ERICH: instead of creating new buffer, could you pass a pointer to the target
// slice in the `Page::data` buffer and write directly?  That would remove the
// need to allocate data and it would remove data copy in `add`
//
// ERICH: I think creating lots of short lived buffers would also create a lot of heap
// growth and GC latency. e.g. If you have a page with a lot of small objects and
// delete one object on the left side of the page, then the delete operation will
// create hundreds of small buffers as it deserializes, reserializes, and copies
// they're short lived but the GC probably won't run enough to keep them from causing
// a lot of fragmentation and heap growth, which could lead to system calls to request
// more memory from the OS.
fn (o PageObject) serialize() []byte {
	mut buf := new_bytes([]byte{})
	buf.write_int(o.length())
	buf.write_int(o.tid)
	buf.write_int(o.xid)
	buf.write_i16(i16(o.key.len))
	buf.write_bytes(o.key)
	buf.write_bytes(o.value)

	return buf.bytes()
}

fn parse_page_object(data []byte) (int, PageObject) {
	mut buf := new_bytes(data)
	total_len := buf.read_int()
	tid := buf.read_int()
	xid := buf.read_int()
	key_len := buf.read_i16()

	return total_len, new_page_object(data[vsql.page_object_prefix_length..key_len +
		vsql.page_object_prefix_length].clone(), tid, xid, data[vsql.page_object_prefix_length +
		key_len..total_len].clone())
}

struct Page {
	kind byte // 0 = leaf, 1 = non-leaf, see constants at the top of the file.
mut:
	used u16    // number of bytes used by this page including 3 bytes for header.
	data []byte // len = page size - 3
}

fn new_page(kind byte, page_size int) &Page {
	return &Page{
		kind: kind
		used: 3 // includes kind and self
		data: []byte{len: page_size - 3}
	}
}

fn (p Page) is_empty() bool {
	return p.used == 3
}

fn (p Page) page_size() int {
	return p.data.len + 3
}

// TODO(elliotchance): This really isn't the most efficient way to do this. Make
//  me faster. Especially since the calls down will recount versions again, etc.
fn (mut p Page) update(old PageObject, new PageObject, tid int) ? {
	mut objects := p.objects()
	old_versions := p.versions(old.key, objects)
	match old_versions.len {
		1 {
			// Expire the existing record.
			p.expire(old.key, old_versions[0], tid)
		}
		2 {
			// Attempt to delete the version for the current in-flight
			// transaction only. If this works, the add() should also work. This
			// handles the case of allowing a record to be updated by the same
			// transaction that still holds it.
			//
			// However, if the version is held not by our transaction the delete
			// will do nothing and the subsequent add() will fail appropriately
			// with SQLSTATE 40001 serialization failure.
			p.delete(old.key, tid)
		}
		else {
			// This would be 0. Nothing to do here. Falldown to the add() below.
		}
	}
}

// versions returns all versions of a record. The result will have 0, 1 or 2
// elements. versions accepts the objects to prevent callers from needing to
// call objects again themselves.
fn (p Page) versions(key []byte, objects []PageObject) []int {
	mut versions := []int{}
	for object in objects {
		if compare_bytes(object.key, key) == 0 {
			// TODO(elliotchance): As long as the database has not become
			//  corrupt, we can stop here at 2. However, I'm going to leave the
			//  full scan in place until the underlying storage is more mature.
			versions << object.tid
		}
	}

	return versions
}

// add will append the object (in order of key) or return an error if either the
// object cannot fit or if their already exists two versions of the key - which
// should be interpreted by the client as a try again. See description below.
fn (mut p Page) add(obj PageObject) ? {
	if p.used + obj.length() > p.page_size() {
		println(p.objects())
		panic('page cannot fit object of $obj.length() b in page using $p.used b')
	}

	// If there are two versions, there must be one version that is
	// frozen (visible to all transactions) and one version that is
	// in-flight for a transaction (and hence only visible to that
	// transaction).
	//
	// We should not let any other transactions create a new version
	// because this would cause a conflict when the COMMIT occurs.
	//
	// We return a SQLSTATE 40001 to let the client know it should retry the
	// entire transaction again.
	mut objects := p.objects() // ERICH: why not have `version` call `objects`?
	if p.versions(obj.key, objects).len >= 2 {
		return sqlstate_40001('avoiding concurrent write on individual row')
	}

	// Make sure the object is added in sorted order. This is not the most
	// efficient way to do this. It will have to do for now.
	objects << obj

	objects.sort_with_compare(fn (a &PageObject, b &PageObject) int {
		return compare_bytes(a.key, b.key)
	})

	mut offset := 0
	for object in objects {
		s := object.serialize()  // ERICH: possible to serialize into the `data` array
		// ERICH: can this be replaced with memcpy?
		for i in 0 .. s.len {
			p.data[offset] = s[i]
			offset++
		}
	}

	p.used += u16(obj.length())
}

// delete will remove a key from a page if it exists, otherwise no action will
// be taken. The index of the deleted object is returned or -1.
fn (mut p Page) delete(key []byte, tid int) bool {
	mut offset := 0
	mut did_delete := false
	for object in p.objects() {
		// If this is the object to delete then remove its length from the used space tracker
		if compare_bytes(key, object.key) == 0 && object.tid == tid {
			p.used -= u16(object.length())
			did_delete = true
			continue
		}

		// ERICH: I don't think there's any reason to do this until `did_delete == true`, bc objects
		// won't shift in `data` until after the deletion point.
		//
		// ERICH: Proposal: split this into two loops. The first searches from the left to the right for the deletion
		//     target.  The second, shifts the bytes to the right of the deleted row over to fill in the vaccuum skipping serde.
		s := object.serialize()  // ERICH: object is already serialized in `p.data` so just copy straight from there?
		for i in 0 .. s.len {
			p.data[offset] = s[i]
			offset++
		}
	}

	return did_delete
}

// expire will set the expiry transaction ID on an existing object. True is
// returned if the page was modified.
fn (mut p Page) expire(key []byte, tid int, xid int) bool {
	mut offset := 0
	mut modified := false
	// ERICH: I may be missing something, but I think all you have to do here is
	//    read the key and the size of the object and nothing else needs to be 
	//    parsed.
	//
	// ERICH: I would break this into two loops: the first loop you scan through
	//     the page to find the matching key and it's offset.  The second loop
	//     you shift all the objects to the right of Delete Offset left, by the
	//     size of the deleted object which can be done by simply copying the raw
	//     bytes.
	for mut object in p.objects() {
		if compare_bytes(key, object.key) == 0 && object.tid == tid {
			object.xid = xid
			modified = true
		}

		s := object.serialize()
		for i in 0 .. s.len {
			p.data[offset] = s[i]
			offset++
		}
	}

	return modified
}

// replace will perform a delete and add operation. If the key does not exist it
// will be created.
fn (mut p Page) replace(key []byte, tid int, value []byte) ? {
	p.delete(key, tid)
	obj := new_page_object(key.clone(), tid, 0, value)
	p.add(obj) ?
}

fn (p Page) keys() [][]byte {
	mut keys := [][]byte{}
	for object in p.objects() {
		keys << object.key
	}

	return keys
}

fn (p Page) objects() []PageObject {
	mut objects := []PageObject{}
	mut n := 0

	for n < p.used - 3 {
		// Be careful to clone the size as the underlying data might get moved
		// around.
		m, object := parse_page_object(p.data[n..].clone())
		objects << object
		n += m
	}

	return objects
}

// head returns the first object in the page, but it must only be used for
// read only (so we can avoid the extra memory copies).
fn (p Page) head() PageObject {
	_, object := parse_page_object(p.data)

	return object
}
