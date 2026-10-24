-- Run once, inside the running container, as SYSDBA.
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
WHENEVER OSERROR EXIT FAILURE ROLLBACK
SET ECHO OFF VERIFY OFF SERVEROUTPUT ON

ALTER SESSION SET CONTAINER = FREEPDB1;
ACCEPT pc_password CHAR PROMPT 'Choose the PLCRAFT application password (no double quotes): ' HIDE

CREATE USER plcraft IDENTIFIED BY "&pc_password"
  DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;
GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE SEQUENCE,
      CREATE PROCEDURE, CREATE TRIGGER, CREATE TYPE, CREATE SYNONYM TO plcraft;
GRANT SELECT ON SYS.V_$MYSTAT TO plcraft;
GRANT SELECT ON SYS.V_$STATNAME TO plcraft;

CONNECT plcraft/"&pc_password"@//localhost:1521/FREEPDB1
UNDEFINE pc_password
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET ECHO OFF VERIFY OFF SERVEROUTPUT ON

ALTER SESSION SET PLSQL_CODE_TYPE = NATIVE;
ALTER SESSION SET PLSQL_OPTIMIZE_LEVEL = 3;
CREATE OR REPLACE PROCEDURE pc_native_check AS
BEGIN
  DBMS_OUTPUT.PUT_LINE('PL/Craft Oracle connection and native compilation work.');
END;
/
EXEC pc_native_check;

DECLARE
  code_type VARCHAR2(20);
BEGIN
  SELECT plsql_code_type INTO code_type
  FROM user_plsql_object_settings
  WHERE name = 'PC_NATIVE_CHECK' AND type = 'PROCEDURE';
  IF code_type <> 'NATIVE' THEN
    RAISE_APPLICATION_ERROR(-20001, 'Native compilation was not enabled');
  END IF;
END;
/
SELECT name, plsql_code_type, plsql_optimize_level
FROM user_plsql_object_settings WHERE name = 'PC_NATIVE_CHECK';
SELECT USER, SYS_CONTEXT('USERENV', 'CON_NAME') AS database_name FROM dual;
SELECT COUNT(*) AS accessible_session_stats FROM v$mystat;
DROP PROCEDURE pc_native_check;
EXIT SUCCESS
