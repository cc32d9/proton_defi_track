CREATE DATABASE proton_defi_track;

CREATE USER 'proton_defi_track'@'localhost' IDENTIFIED BY 'keiH8eej';
GRANT ALL ON proton_defi_track.* TO 'proton_defi_track'@'localhost';
grant SELECT on proton_defi_track.* to 'proton_defi_track_ro'@'%' identified by 'proton_defi_track_ro';

use proton_defi_track;

CREATE TABLE SYNC
(
 network           VARCHAR(15) PRIMARY KEY,
 block_num         BIGINT NOT NULL,
 block_time        DATETIME NOT NULL
) ENGINE=InnoDB;



