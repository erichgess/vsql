DROP TABLE foo
-- error: vdb.SQLState42P01: no such table: foo

CREATE TABLE foo (a FLOAT)
DROP TABLE foo
DROP TABLE foo
-- msg: CREATE TABLE 1
-- msg: DROP TABLE 1
-- error: vdb.SQLState42P01: no such table: foo
