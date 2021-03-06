-- == Master db ==

-- create python language: (uncomment if not installed, must be superuser):
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
      filter_plan = SD["filter_plan"]
  else:
      plan = plpy.prepare("INSERT INTO replica_log (sql) VALUES ($1)", ["text"])
      SD["plan"] = plan
      filter_plan = plpy.prepare("SELECT * FROM py_log_filter WHERE relname=$1 and event=$2", ["text","text"])
      SD["filter_plan"] = filter_plan

  new = TD['new']
  old = TD['old']
  event = TD['event']

  # arguments passed in CREATE TRIGGER (specify relname and primary keys)
  args = TD['args'] 
  relname = args[0]
  primary_keys = args[1:]

  # get filter condition:
  rows = plpy.execute(filter_plan, (relname, event))
  for row in rows:
    if not eval(row['condition'],{"new": new,"old": old}):
       plpy.notice("pyreplica cond fail %s" % row['condition'])
       event = None # row doesn't pass filter cond
       sql = ""
    else:
       plpy.notice("pyreplica cond ok %s" % row['condition'])

  # make sql according with trigger DML action
  if event == 'INSERT':
    sql = 'INSERT INTO "%s" (%s) VALUES (%s)' % (
            relname,
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
      sql = 'UPDATE "%s" SET %s WHERE %s' % (
            relname,
            ', '.join(['"%s"=%s' % (k,mogrify(v)) for k,v in modified]),
            ' AND '.join(['"%s"=%s' % (k,mogrify(v)) for k,v in old.items() if k in primary_keys]),
          )
    else:
      sql = ""
  elif event == 'DELETE':
    sql = 'DELETE FROM "%s" WHERE %s' % (
            relname,
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

-- create filter table (where python conditions are stored):
CREATE TABLE py_log_filter (relname text, event text, condition text);


-- setup permission (if applicable, uncomment and change username):

--GRANT ALL ON replica_log_id_seq TO someone; 
--GRANT ALL ON replica_log TO someone; 
--GRANT ALL ON py_log_filter TO someone; 


-- for each table that needs replication (on master db), create a trigger like this:
-- CREATE TRIGGER test_replica_tg AFTER INSERT OR UPDATE OR DELETE ON test FOR EACH ROW EXECUTE PROCEDURE py_log_replica('test', 'id1', 'id2');
-- where 'test' is the table name and ('id1','id2') is the primary key 


-- == Automatically install trigger to all tables ==

CREATE OR REPLACE FUNCTION py_log_create_tg(relname varchar) returns text AS
$BODY$
relname = args[0]

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
  AFTER INSERT OR UPDATE OR DELETE ON %(relname)s 
  FOR EACH ROW EXECUTE PROCEDURE py_log_replica('%(relname)s', %(keys)s);
""" % {'relname':relname,'keys':','.join(keys)})

  return "created trigger on %s (%s) " % (relname, ','.join(keys))

  ## $BODY$
  LANGUAGE 'plpythonu' VOLATILE;

-- create trigger for all tables:

SELECT py_log_create_tg(relname::text) FROM pg_class WHERE relname !~ '^(pg_|sql_)' AND relkind = 'r' AND relname != 'replica_log' ;

