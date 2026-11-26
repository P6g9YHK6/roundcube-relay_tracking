-- relay_tracking: self tracking (open pixel and links served by Roundcube)

CREATE TABLE `relay_tracking_mail` (
 `token` varchar(32) NOT NULL,
 `user_id` int(10) UNSIGNED NOT NULL,
 `message_id` varchar(255) NOT NULL,
 `links` longtext NOT NULL,
 `created` datetime NOT NULL DEFAULT '1000-01-01 00:00:00',
 PRIMARY KEY (`token`),
 CONSTRAINT `user_id_fk_relay_tracking_mail` FOREIGN KEY (`user_id`)
   REFERENCES `users` (`user_id`) ON DELETE CASCADE ON UPDATE CASCADE,
 INDEX `relay_tracking_mail_user_index` (`user_id`, `message_id`),
 INDEX `relay_tracking_mail_created_index` (`created`)
) ROW_FORMAT=DYNAMIC ENGINE=INNODB CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE TABLE `relay_tracking_hit` (
 `hit_id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT,
 `token` varchar(32) NOT NULL,
 `created` datetime NOT NULL DEFAULT '1000-01-01 00:00:00',
 `type` varchar(16) NOT NULL,
 `extra` text,
 `ip` varchar(45),
 PRIMARY KEY (`hit_id`),
 CONSTRAINT `token_fk_relay_tracking_hit` FOREIGN KEY (`token`)
   REFERENCES `relay_tracking_mail` (`token`) ON DELETE CASCADE ON UPDATE CASCADE,
 INDEX `relay_tracking_hit_token_index` (`token`)
) ROW_FORMAT=DYNAMIC ENGINE=INNODB CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
