-- relay_tracking: self tracking (open pixel and links served by Roundcube)

CREATE TABLE relay_tracking_mail (
    token varchar(32) PRIMARY KEY,
    user_id integer NOT NULL
        REFERENCES users (user_id) ON DELETE CASCADE ON UPDATE CASCADE,
    message_id varchar(255) NOT NULL,
    links text NOT NULL,
    created timestamp without time zone NOT NULL
);

CREATE INDEX relay_tracking_mail_user_idx ON relay_tracking_mail (user_id, message_id);
CREATE INDEX relay_tracking_mail_created_idx ON relay_tracking_mail (created);

CREATE SEQUENCE relay_tracking_hit_seq
    START WITH 1
    INCREMENT BY 1
    NO MAXVALUE
    NO MINVALUE
    CACHE 1;

CREATE TABLE relay_tracking_hit (
    hit_id integer DEFAULT nextval('relay_tracking_hit_seq'::text) PRIMARY KEY,
    token varchar(32) NOT NULL
        REFERENCES relay_tracking_mail (token) ON DELETE CASCADE ON UPDATE CASCADE,
    created timestamp without time zone NOT NULL,
    type varchar(16) NOT NULL,
    extra text,
    ip varchar(45)
);

CREATE INDEX relay_tracking_hit_token_idx ON relay_tracking_hit (token);
