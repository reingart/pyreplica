-- stop pyreplica

-- upgrade from < 1.0.5

-- to detect update conflicts, recreate py_log_replica function and restart backend

-- upgrade from < 1.0.4

alter table replica_log add column username name default CURRENT_USER;

-- upgrade from < 1.0.2

ALTER TABLE replica_log ADD COLUMN replicated BOOLEAN DEFAULT FALSE;
UPDATE replica_log SET replicated=TRUE WHERE ID< (see current replica_log_id_seq value in slave);

-- restart postgresql and pyreplica