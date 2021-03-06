-- == Master db ==

-- Trigger installation script. Run:
--   bash# psql -Upostgres database < master-install.sql
--
-- Before run, please modify the script if you want to replicate only a specified
-- schema (the query at the end of this code).

-- create python language: (comment if already installed, must be superuser):
CREATE LANGUAGE plpythonu;

-- create replica function
CREATE OR REPLACE FUNCTION py_log_replica()
  RETURNS "trigger" AS
$BODY$

  # Change if you don't want to check data conflicts (inserts a SELECT query)
  warn_conflicts = True 

  # function to convert value from python to postgres representation
  def mogrify(v):
    if v is None: return 'NULL' 
    if isinstance(v,long): return str(v) # don't add long prefix L (bigint)
    if isinstance(v,basestring): 
       r = repr(v)
       if not r.startswith('\"'):
          return r
       else:
          # postgres doesn't support ", replace and escape '
          return "'%s'" % r.replace("'","\\'")[1:-1]
    return "'%s'" % repr(v) # to get rid of bool that are passed as ints (solved in pg8.3)

  # retrieve or prepare plan for faster processing
  if SD.has_key("plan"):
      plan = SD["plan"]
  else:
      plan = plpy.prepare("INSERT INTO replica_log (sql) VALUES ($1)", ["text"])
      SD["plan"] = plan

  new = TD['new']
  old = TD['old']
  event = TD['event']

  # arguments passed in CREATE TRIGGER (specify relname and primary keys)
  args = TD['args'] 
  schemaname = args[0]
  relname = args[1]
  primary_keys = args[2:]

  # make sql according with trigger DML action
  if event == 'INSERT':
    sql = 'INSERT INTO "%s"."%s" (%s) VALUES (%s)' % (
            schemaname,relname,
            ', '.join(['"%s"' % k for k in new.keys()]),
            ', '.join([mogrify(v) for v in new.values()]),
          )
  elif event == 'UPDATE':
    modified = [(k,v) for (k,v) in new.items() if old[k]<>v]
    if modified: # only if there are modified fields
      if warn_conflicts:
        # Insert a query to warn if there is a data conflict
        sql = 'SELECT %s,%s,%s FROM "%s" WHERE %s AND (%s) ' % (
            ', '.join(['%s AS "old_%s"' % (k,k) for k,v in modified]),
            ', '.join(['%s AS "new_%s"' % (mogrify(v),k) for k,v in modified]),
            ', '.join(['%s AS "expected_%s"' % (mogrify(old[k]),k) for k,v in modified]),
            relname,
            ' AND '.join(['"%s" = %s' % (k,mogrify(v)) for k,v in old.items() if k in primary_keys]),
            ' OR '.join(['"%s"<>%s' % (k,mogrify(v)) for k,v in old.items() if k in [km for (km,vm) in modified]]),
        )
        plpy.execute(plan, [ sql ], 0)
      sql = 'UPDATE "%s"."%s" SET %s WHERE %s' % (
            schemaname,relname,
            ', '.join(['"%s"=%s' % (k,mogrify(v)) for k,v in modified]),
            ' AND '.join(['"%s"=%s' % (k,mogrify(v)) for k,v in old.items() if k in primary_keys]),
          )
    else:
      sql = ""
  elif event == 'DELETE':
    sql = 'DELETE FROM "%s"."%s" WHERE %s' % (
            schemaname,relname,
            ' AND '.join(['"%s"=%s' % (k,mogrify(v)) for k,v in old.items() if k in primary_keys]),
          )

  # verify that there is a sql query to log  
  if sql:
    # store trigger log sql
    plpy.execute(plan, [ sql ], 0)

    # notify listeners that new data is available
    r = plpy.execute('NOTIFY "replicas"', 0)

  #plpy.debug (sql)
  

  ## $BODY$
  LANGUAGE 'plpythonu' VOLATILE;

-- create log table (where sql replica queries are stored):

CREATE TABLE replica_log (
 id SERIAL PRIMARY KEY,
 sql TEXT,
 replicated BOOLEAN DEFAULT FALSE,
 username NAME DEFAULT CURRENT_USER,
 ts TIMESTAMP DEFAULT now()
) WITHOUT OIDS ;

-- setup permission (if applicable, uncomment and change username):

--GRANT ALL ON replica_log_id_seq TO someone; 
--GRANT ALL ON replica_log TO someone; 


-- for each table that needs replication (on master db), create a trigger like this:
-- CREATE TRIGGER test_replica_tg AFTER INSERT OR UPDATE OR DELETE ON test FOR EACH ROW EXECUTE PROCEDURE py_log_replica('test', 'id1', 'id2');
-- where 'test' is the table name and ('id1','id2') is the primary key 


-- == Automatically install trigger to all tables ==

CREATE OR REPLACE FUNCTION py_log_create_tg(schemaname varchar , relname varchar) returns text AS
$BODY$
schemaname = args[0]
relname = args[1]


# find PK constraints
rv = plpy.execute("""SELECT c.conname
FROM pg_constraint c
LEFT JOIN pg_class t  ON c.conrelid  = t.oid
LEFT JOIN pg_class t2 ON c.confrelid = t2.oid
    WHERE t.relname = '%s' and c.contype='p'""" % relname,1);

if not rv:
  return "table %s has no pk constraint (couln't be replicated)! " % (relname)
else:
  conname = rv[0]['conname']

  # find primary keys:
  rv = plpy.execute("""SELECT kcu.column_name
     FROM information_schema.table_constraints tc
LEFT JOIN information_schema.key_column_usage kcu
       ON tc.constraint_catalog = kcu.constraint_catalog
      AND tc.constraint_schema = kcu.constraint_schema
      AND tc.constraint_name = kcu.constraint_name
    WHERE tc.table_name = '%s' 
      AND tc.constraint_name = '%s';""" % (relname,conname))

  keys = []
  for r in rv:
    keys.append(r['column_name'])

  # drop current trigger (if any) 
  #try:
  #   plpy.execute("DROP TRIGGER %(relname)s_replica_tg ON %(relname)s;" % {'relname':relname,})
  #except:
  #   pass

  # create triggers:
  plpy.execute("""
CREATE TRIGGER %(relname)s_replica_tg 
  AFTER INSERT OR UPDATE OR DELETE ON %(schemaname)s.%(relname)s 
  FOR EACH ROW EXECUTE PROCEDURE py_log_replica('%(schemaname)s','%(relname)s', %(keys)s);
""" % {'schemaname':schemaname,'relname':relname,'keys':','.join(keys)})

  return "created trigger on %s.%s (%s) " % (schemaname,relname, ','.join(keys))

  ## $BODY$
  LANGUAGE 'plpythonu' VOLATILE;

-- create trigger for all tables:
SELECT py_log_create_tg(schemaname::text, tablename::text) from pg_tables where tablename !~ '^(pg_|sql_)' AND tablename != 'replica_log' ;
-- Check which tables are included in the set:
SELECT schemaname::text, tablename::text from pg_tables where tablename !~ '^(pg_|sql_)' AND tablename != 'replica_log' ;


-- If you want to replicate only 1 schema use:
-- SELECT py_log_create_tg(schemaname::text, tablename::text) from pg_tables where tablename !~ '^(pg_|sql_)' AND tablename != 'replica_log' AND schemaname = 'your_schema_name';
-- Uncomment the next statement if you want echo which tables have been included:
-- SELECT schemaname::text, tablename::text from pg_tables where tablename !~ '^(pg_|sql_)' AND tablename != 'replica_log'  AND schemaname = 'your_schema_name';
