CREATE KEYSPACE IF NOT EXISTS bank 
WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};

# Table des donnees gess
CREATE TABLE IF NOT EXISTS bank.transactions (
    account_id text,
    transaction_id uuid,
    timestamp timestamp,
    atm text,
    amount double,
    latitude double,
    longitude double,
    PRIMARY KEY ((account_id), timestamp)
) WITH CLUSTERING ORDER BY (timestamp DESC);


CREATE TABLE IF NOT EXISTS bank.possible_fraud (
  ACCOUNT_ID text,
  TX1_TRANSACTION_ID uuid,
  TX1_TIMESTAMP timestamp,
  TX1_AMOUNT    double,
  TX1_LATITUDE  double,
  TX1_LONGITUDE double,
  TX1_ATM 		text,
  TX2_TRANSACTION_ID uuid,
  TX2_TIMESTAMP timestamp,
  TX2_AMOUNT    double,
  TX2_LATITUDE  double,
  TX2_LONGITUDE double,
  TX2_ATM 		text,
  DISTANCE_IN_KM double,
  SHIFT_IN_MILLIS integer,
  SHIFT_IN_MINUTE double,
  KMH_REQUIRED double,
  PRIMARY KEY ((ACCOUNT_ID), TX1_TIMESTAMP, TX2_TIMESTAMP)
) WITH CLUSTERING ORDER BY (TX1_TIMESTAMP DESC, TX1_TIMESTAMP DESC);

