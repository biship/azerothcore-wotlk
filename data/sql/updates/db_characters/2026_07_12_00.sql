-- DB update 2026_06_24_00 -> 2026_07_12_00
-- Add persistent player travel statistics.
CREATE TABLE IF NOT EXISTS `character_travel_stats` (
    `guid` INT UNSIGNED NOT NULL DEFAULT '0' COMMENT 'Global Unique Identifier',
    `walked` BIGINT UNSIGNED NOT NULL DEFAULT '0' COMMENT 'Walking and running distance',
    `mounted` BIGINT UNSIGNED NOT NULL DEFAULT '0' COMMENT 'Mounted distance',
    `swimming` BIGINT UNSIGNED NOT NULL DEFAULT '0' COMMENT 'Swimming distance',
    `flying` BIGINT UNSIGNED NOT NULL DEFAULT '0' COMMENT 'Flying distance',
    PRIMARY KEY (`guid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
