-- relay_tracking: self tracking (open pixel and links served by Roundcube)

CREATE TABLE relay_tracking_mail (
  token varchar(32) NOT NULL PRIMARY KEY,
  user_id integer NOT NULL
    REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE,
  message_id varchar(255) NOT NULL,
  links text NOT NULL,
  created datetime NOT NULL default '0000-00-00 00:00:00'
);

CREATE INDEX ix_relay_tracking_mail_user ON relay_tracking_mail(user_id, message_id);
CREATE INDEX ix_relay_tracking_mail_created ON relay_tracking_mail(created);

CREATE TABLE relay_tracking_hit (
  hit_id integer NOT NULL PRIMARY KEY,
  token varchar(32) NOT NULL
    REFERENCES relay_tracking_mail (token) ON DELETE CASCADE ON UPDATE CASCADE,
  created datetime NOT NULL default '0000-00-00 00:00:00',
  type varchar(16) NOT NULL,
  extra text,
  ip varchar(45)
);

CREATE INDEX ix_relay_tracking_hit_token ON relay_tracking_hit(token);
