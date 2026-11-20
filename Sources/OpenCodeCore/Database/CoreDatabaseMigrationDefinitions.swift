#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodePlatform

extension CoreDatabaseMigration {
    /// Individual canonical SQLite schema and data migration definitions matching `core/src/database/migration/*.ts`.
    public enum Migrations {
        private static func sqlMigration(id: String, foreignKeys: Bool = true, statements: [String]) -> Migration {
            Migration(id: id, foreignKeys: foreignKeys) { tx, _ in
                for statement in statements {
                    _ = try tx.execute(statement)
                }
            }
        }

        // parity: core/src/database/migration/20260127222353_familiar_lady_ursula.ts#default [status=implemented hash=30d635f954ac]
        public static let m_20260127222353_familiar_lady_ursula = sqlMigration(id: "20260127222353_familiar_lady_ursula", statements: [
            "CREATE TABLE `project` ( `id` text PRIMARY KEY, `worktree` text NOT NULL, `vcs` text, `name` text, `icon_url` text, `icon_color` text, `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `time_initialized` integer, `sandboxes` text NOT NULL );",
            "CREATE TABLE `message` ( `id` text PRIMARY KEY, `session_id` text NOT NULL, `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `data` text NOT NULL, CONSTRAINT `fk_message_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE );",
            "CREATE TABLE `part` ( `id` text PRIMARY KEY, `message_id` text NOT NULL, `session_id` text NOT NULL, `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `data` text NOT NULL, CONSTRAINT `fk_part_message_id_message_id_fk` FOREIGN KEY (`message_id`) REFERENCES `message`(`id`) ON DELETE CASCADE );",
            "CREATE TABLE `permission` ( `project_id` text PRIMARY KEY, `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `data` text NOT NULL, CONSTRAINT `fk_permission_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE );",
            "CREATE TABLE `session` ( `id` text PRIMARY KEY, `project_id` text NOT NULL, `parent_id` text, `slug` text NOT NULL, `directory` text NOT NULL, `title` text NOT NULL, `version` text NOT NULL, `share_url` text, `summary_additions` integer, `summary_deletions` integer, `summary_files` integer, `summary_diffs` text, `revert` text, `permission` text, `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `time_compacting` integer, `time_archived` integer, CONSTRAINT `fk_session_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE );",
            "CREATE TABLE `todo` ( `session_id` text NOT NULL, `content` text NOT NULL, `status` text NOT NULL, `priority` text NOT NULL, `position` integer NOT NULL, `time_created` integer NOT NULL, `time_updated` integer NOT NULL, CONSTRAINT `todo_pk` PRIMARY KEY(`session_id`, `position`), CONSTRAINT `fk_todo_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE );",
            "CREATE TABLE `session_share` ( `session_id` text PRIMARY KEY, `id` text NOT NULL, `secret` text NOT NULL, `url` text NOT NULL, `time_created` integer NOT NULL, `time_updated` integer NOT NULL, CONSTRAINT `fk_session_share_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE );",
            "CREATE INDEX `message_session_idx` ON `message` (`session_id`);",
            "CREATE INDEX `part_message_idx` ON `part` (`message_id`);",
            "CREATE INDEX `part_session_idx` ON `part` (`session_id`);",
            "CREATE INDEX `session_project_idx` ON `session` (`project_id`);",
            "CREATE INDEX `session_parent_idx` ON `session` (`parent_id`);",
            "CREATE INDEX `todo_session_idx` ON `todo` (`session_id`);",
        ])

        // parity: core/src/database/migration/20260211171708_add_project_commands.ts#default [status=implemented hash=0e1ee4faf1b0]
        public static let m_20260211171708_add_project_commands = sqlMigration(id: "20260211171708_add_project_commands", statements: [
            "ALTER TABLE `project` ADD `commands` text;",
        ])

        // parity: core/src/database/migration/20260213144116_wakeful_the_professor.ts#default [status=implemented hash=9ed977821f10]
        public static let m_20260213144116_wakeful_the_professor = sqlMigration(id: "20260213144116_wakeful_the_professor", statements: [
            "CREATE TABLE `control_account` ( `email` text NOT NULL, `url` text NOT NULL, `access_token` text NOT NULL, `refresh_token` text NOT NULL, `token_expiry` integer, `active` integer NOT NULL, `time_created` integer NOT NULL, `time_updated` integer NOT NULL, CONSTRAINT `control_account_pk` PRIMARY KEY(`email`, `url`) );",
        ])

        // parity: core/src/database/migration/20260225215848_workspace.ts#default [status=implemented hash=e7a2b470a4f6]
        public static let m_20260225215848_workspace = sqlMigration(id: "20260225215848_workspace", statements: [
            "CREATE TABLE `workspace` ( `id` text PRIMARY KEY, `branch` text, `project_id` text NOT NULL, `config` text NOT NULL, CONSTRAINT `fk_workspace_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE );",
        ])

        // parity: core/src/database/migration/20260227213759_add_session_workspace_id.ts#default [status=implemented hash=67662ee2990c]
        public static let m_20260227213759_add_session_workspace_id = sqlMigration(id: "20260227213759_add_session_workspace_id", statements: [
            "ALTER TABLE `session` ADD `workspace_id` text;",
            "CREATE INDEX `session_workspace_idx` ON `session` (`workspace_id`);",
        ])

        // parity: core/src/database/migration/20260228203230_blue_harpoon.ts#default [status=implemented hash=1cc45c465e3b]
        public static let m_20260228203230_blue_harpoon = sqlMigration(id: "20260228203230_blue_harpoon", statements: [
            "CREATE TABLE `account` ( `id` text PRIMARY KEY, `email` text NOT NULL, `url` text NOT NULL, `access_token` text NOT NULL, `refresh_token` text NOT NULL, `token_expiry` integer, `selected_org_id` text, `time_created` integer NOT NULL, `time_updated` integer NOT NULL );",
            "CREATE TABLE `account_state` ( `id` integer PRIMARY KEY NOT NULL, `active_account_id` text, FOREIGN KEY (`active_account_id`) REFERENCES `account`(`id`) ON UPDATE no action ON DELETE set null );",
        ])

        // parity: core/src/database/migration/20260303231226_add_workspace_fields.ts#default [status=implemented hash=db3bfdde55b8]
        public static let m_20260303231226_add_workspace_fields = sqlMigration(id: "20260303231226_add_workspace_fields", statements: [
            "ALTER TABLE `workspace` ADD `type` text NOT NULL;",
            "ALTER TABLE `workspace` ADD `name` text;",
            "ALTER TABLE `workspace` ADD `directory` text;",
            "ALTER TABLE `workspace` ADD `extra` text;",
            "ALTER TABLE `workspace` DROP COLUMN `config`;",
        ])

        // parity: core/src/database/migration/20260309230000_move_org_to_state.ts#default [status=implemented hash=82d3e8af5b4e]
        public static let m_20260309230000_move_org_to_state = sqlMigration(id: "20260309230000_move_org_to_state", statements: [
            "ALTER TABLE `account_state` ADD `active_org_id` text;",
            "UPDATE `account_state` SET `active_org_id` = (SELECT `selected_org_id` FROM `account` WHERE `account`.`id` = `account_state`.`active_account_id`);",
            "ALTER TABLE `account` DROP COLUMN `selected_org_id`;",
        ])

        // parity: core/src/database/migration/20260312043431_session_message_cursor.ts#default [status=implemented hash=58594f78cbb7]
        public static let m_20260312043431_session_message_cursor = sqlMigration(id: "20260312043431_session_message_cursor", statements: [
            "DROP INDEX IF EXISTS `message_session_idx`;",
            "DROP INDEX IF EXISTS `part_message_idx`;",
            "CREATE INDEX `message_session_time_created_id_idx` ON `message` (`session_id`,`time_created`,`id`);",
            "CREATE INDEX `part_message_id_id_idx` ON `part` (`message_id`,`id`);",
        ])

        // parity: core/src/database/migration/20260323234822_events.ts#default [status=implemented hash=0f465d2c4bba]
        public static let m_20260323234822_events = sqlMigration(id: "20260323234822_events", statements: [
            "CREATE TABLE `event_sequence` ( `aggregate_id` text PRIMARY KEY, `seq` integer NOT NULL );",
            "CREATE TABLE `event` ( `id` text PRIMARY KEY, `aggregate_id` text NOT NULL, `seq` integer NOT NULL, `type` text NOT NULL, `data` text NOT NULL, CONSTRAINT `fk_event_aggregate_id_event_sequence_aggregate_id_fk` FOREIGN KEY (`aggregate_id`) REFERENCES `event_sequence`(`aggregate_id`) ON DELETE CASCADE );",
        ])

        // parity: core/src/database/migration/20260410174513_workspace-name.ts#default [status=implemented hash=475a3616069a]
        public static let m_20260410174513_workspace_name = Migration(id: "20260410174513_workspace-name") { tx, _ in
            let cols = try tx.query("PRAGMA table_info(`workspace`)")
            let nameExpr = cols.contains(where: { $0.string("name") == "name" }) ? "`name`" : "''"
            _ = try tx.execute("PRAGMA foreign_keys=OFF;")
            _ = try tx.execute("CREATE TABLE `__new_workspace` (`id` text PRIMARY KEY, `type` text NOT NULL, `name` text DEFAULT '' NOT NULL, `branch` text, `directory` text, `extra` text, `project_id` text NOT NULL, CONSTRAINT `fk_workspace_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE);")
            _ = try tx.execute("INSERT INTO `__new_workspace`(`id`, `type`, `branch`, `name`, `directory`, `extra`, `project_id`) SELECT `id`, `type`, `branch`, \(nameExpr), `directory`, `extra`, `project_id` FROM `workspace`;")
            _ = try tx.execute("DROP TABLE `workspace`;")
            _ = try tx.execute("ALTER TABLE `__new_workspace` RENAME TO `workspace`;")
            _ = try tx.execute("PRAGMA foreign_keys=ON;")
        }

        // parity: core/src/database/migration/20260413175956_chief_energizer.ts#default [status=implemented hash=757472527e9c]
        public static let m_20260413175956_chief_energizer = sqlMigration(id: "20260413175956_chief_energizer", statements: [
            "CREATE TABLE `session_entry` ( `id` text PRIMARY KEY, `session_id` text NOT NULL, `type` text NOT NULL, `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `data` text NOT NULL, CONSTRAINT `fk_session_entry_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE );",
            "CREATE INDEX `session_entry_session_idx` ON `session_entry` (`session_id`);",
            "CREATE INDEX `session_entry_session_type_idx` ON `session_entry` (`session_id`,`type`);",
            "CREATE INDEX `session_entry_time_created_idx` ON `session_entry` (`time_created`);",
        ])

        // parity: core/src/database/migration/20260423070820_add_icon_url_override.ts#default [status=implemented hash=f263fcb7ce68]
        public static let m_20260423070820_add_icon_url_override = sqlMigration(id: "20260423070820_add_icon_url_override", statements: [
            "ALTER TABLE `project` ADD `icon_url_override` text; UPDATE `project` SET `icon_url_override` = `icon_url` WHERE `icon_url` IS NOT NULL;",
        ])

        // parity: core/src/database/migration/20260427172553_slow_nightmare.ts#default [status=implemented hash=44a12134cbcb]
        public static let m_20260427172553_slow_nightmare = sqlMigration(id: "20260427172553_slow_nightmare", statements: [
            "CREATE TABLE `session_message` ( `id` text PRIMARY KEY, `session_id` text NOT NULL, `type` text NOT NULL, `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `data` text NOT NULL, CONSTRAINT `fk_session_message_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE );",
            "DROP INDEX IF EXISTS `session_entry_session_idx`;",
            "DROP INDEX IF EXISTS `session_entry_session_type_idx`;",
            "DROP INDEX IF EXISTS `session_entry_time_created_idx`;",
            "CREATE INDEX `session_message_session_idx` ON `session_message` (`session_id`);",
            "CREATE INDEX `session_message_session_type_idx` ON `session_message` (`session_id`,`type`);",
            "CREATE INDEX `session_message_time_created_idx` ON `session_message` (`time_created`);",
            "DROP TABLE `session_entry`;",
        ])

        // parity: core/src/database/migration/20260428004200_add_session_path.ts#default [status=implemented hash=5e2e80a3f235]
        public static let m_20260428004200_add_session_path = sqlMigration(id: "20260428004200_add_session_path", statements: [
            "ALTER TABLE `session` ADD `path` text;",
        ])

        // parity: core/src/database/migration/20260501142318_next_venus.ts#default [status=implemented hash=2f892dc9ed82]
        public static let m_20260501142318_next_venus = sqlMigration(id: "20260501142318_next_venus", statements: [
            "ALTER TABLE `session` ADD `agent` text;",
            "ALTER TABLE `session` ADD `model` text;",
        ])

        // parity: core/src/database/migration/20260504145000_add_sync_owner.ts#default [status=implemented hash=8158b6707fc4]
        public static let m_20260504145000_add_sync_owner = sqlMigration(id: "20260504145000_add_sync_owner", statements: [
            "ALTER TABLE `event_sequence` ADD `owner_id` text;",
        ])

        // parity: core/src/database/migration/20260507164347_add_workspace_time.ts#default [status=implemented hash=1f71803c58bb]
        public static let m_20260507164347_add_workspace_time = sqlMigration(id: "20260507164347_add_workspace_time", statements: [
            "ALTER TABLE `workspace` ADD `time_used` integer NOT NULL DEFAULT 0;",
        ])

        // parity: core/src/database/migration/20260510033149_session_usage.ts#default [status=implemented hash=ec60f5a9d674]
        public static let m_20260510033149_session_usage = sqlMigration(id: "20260510033149_session_usage", statements: [
            "ALTER TABLE `session` ADD `cost` real DEFAULT 0 NOT NULL;",
            "ALTER TABLE `session` ADD `tokens_input` integer DEFAULT 0 NOT NULL;",
            "ALTER TABLE `session` ADD `tokens_output` integer DEFAULT 0 NOT NULL;",
            "ALTER TABLE `session` ADD `tokens_reasoning` integer DEFAULT 0 NOT NULL;",
            "ALTER TABLE `session` ADD `tokens_cache_read` integer DEFAULT 0 NOT NULL;",
            "ALTER TABLE `session` ADD `tokens_cache_write` integer DEFAULT 0 NOT NULL;",
            "UPDATE session SET cost = coalesce(( SELECT sum(coalesce(json_extract(message.data, '$.cost'), 0)) FROM message WHERE message.session_id = session.id AND json_extract(message.data, '$.role') = 'assistant' ), 0), tokens_input = coalesce(( SELECT sum(coalesce(json_extract(message.data, '$.tokens.input'), 0)) FROM message WHERE message.session_id = session.id AND json_extract(message.data, '$.role') = 'assistant' ), 0), tokens_output = coalesce(( SELECT sum(coalesce(json_extract(message.data, '$.tokens.output'), 0)) FROM message WHERE message.session_id = session.id AND json_extract(message.data, '$.role') = 'assistant' ), 0), tokens_reasoning = coalesce(( SELECT sum(coalesce(json_extract(message.data, '$.tokens.reasoning'), 0)) FROM message WHERE message.session_id = session.id AND json_extract(message.data, '$.role') = 'assistant' ), 0), tokens_cache_read = coalesce(( SELECT sum(coalesce(json_extract(message.data, '$.tokens.cache.read'), 0)) FROM message WHERE message.session_id = session.id AND json_extract(message.data, '$.role') = 'assistant' ), 0), tokens_cache_write = coalesce(( SELECT sum(coalesce(json_extract(message.data, '$.tokens.cache.write'), 0)) FROM message WHERE message.session_id = session.id AND json_extract(message.data, '$.role') = 'assistant' ), 0)",
        ])

        // parity: core/src/database/migration/20260511000411_data_migration_state.ts#default [status=implemented hash=7b3772db4f49]
        public static let m_20260511000411_data_migration_state = sqlMigration(id: "20260511000411_data_migration_state", statements: [
            "CREATE TABLE `data_migration` ( `name` text PRIMARY KEY, `time_completed` integer NOT NULL );",
        ])

        // parity: core/src/database/migration/20260511173437_session-metadata.ts#default [status=implemented hash=285edc79bb30]
        public static let m_20260511173437_session_metadata = Migration(id: "20260511173437_session-metadata") { tx, _ in
            let cols = try tx.query("PRAGMA table_info(`session`)")
            if cols.contains(where: { $0.string("name") == "metadata" }) { return }
            _ = try tx.execute("ALTER TABLE `session` ADD `metadata` text;")
        }

        // parity: core/src/database/migration/20260601010001_normalize_storage_paths.ts#default [status=implemented hash=eba83e12aac4]
        public static let m_20260601010001_normalize_storage_paths = sqlMigration(id: "20260601010001_normalize_storage_paths", statements: [
            "UPDATE project SET worktree = REPLACE(worktree, char(92), '/') WHERE worktree GLOB '[A-Za-z]:' || char(92) || '*' OR worktree LIKE char(92) || char(92) || '%';",
            "UPDATE project SET sandboxes = REPLACE(sandboxes, char(92) || char(92), '/') WHERE instr(sandboxes, char(92)) > 0 AND (worktree GLOB '[A-Za-z]:*' OR worktree LIKE '//%');",
            "UPDATE session SET directory = REPLACE(directory, char(92), '/') WHERE directory GLOB '[A-Za-z]:' || char(92) || '*' OR directory LIKE char(92) || char(92) || '%';",
            "UPDATE session SET path = REPLACE(path, char(92), '/') WHERE path IS NOT NULL AND instr(path, char(92)) > 0 AND (directory GLOB '[A-Za-z]:*' OR directory LIKE '//%');",
        ])

        // parity: core/src/database/migration/20260601202201_amazing_prowler.ts#default [status=implemented hash=ccb53eb6a907]
        public static let m_20260601202201_amazing_prowler = sqlMigration(id: "20260601202201_amazing_prowler", statements: [
            "DROP TABLE `permission`;",
        ])

        // parity: core/src/database/migration/20260602002951_lowly_union_jack.ts#default [status=implemented hash=251536e52d1c]
        public static let m_20260602002951_lowly_union_jack = sqlMigration(id: "20260602002951_lowly_union_jack", statements: [
            "CREATE TABLE `permission` ( `id` text PRIMARY KEY, `project_id` text NOT NULL, `action` text NOT NULL, `resource` text NOT NULL, `time_created` integer NOT NULL, `time_updated` integer NOT NULL, CONSTRAINT `fk_permission_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE );",
            "CREATE UNIQUE INDEX `permission_project_action_resource_idx` ON `permission` (`project_id`,`action`,`resource`);",
        ])

        // parity: core/src/database/migration/20260602182828_add_project_directories.ts#default [status=implemented hash=1b14aa76ee55]
        public static let m_20260602182828_add_project_directories = sqlMigration(id: "20260602182828_add_project_directories", statements: [
            "CREATE TABLE `project_directory` ( `project_id` text NOT NULL, `directory` text NOT NULL, `type` text NOT NULL, `time_created` integer NOT NULL, CONSTRAINT `project_directory_pk` PRIMARY KEY(`project_id`, `directory`), CONSTRAINT `fk_project_directory_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE );",
        ])

        // parity: core/src/database/migration/20260603001617_session_message_projection_indexes.ts#default [status=implemented hash=33f755396bb6]
        public static let m_20260603001617_session_message_projection_indexes = sqlMigration(id: "20260603001617_session_message_projection_indexes", statements: [
            "DROP INDEX IF EXISTS `session_message_session_idx`;",
            "DROP INDEX IF EXISTS `session_message_session_type_idx`;",
            "CREATE INDEX `event_aggregate_seq_idx` ON `event` (`aggregate_id`,`seq`);",
            "CREATE INDEX `session_message_session_time_created_id_idx` ON `session_message` (`session_id`,`time_created`,`id`);",
            "CREATE INDEX `session_message_session_type_time_created_id_idx` ON `session_message` (`session_id`,`type`,`time_created`,`id`);",
        ])

        // parity: core/src/database/migration/20260603040000_session_message_projection_order.ts#default [status=implemented hash=e944cc8b1a68]
        public static let m_20260603040000_session_message_projection_order = sqlMigration(id: "20260603040000_session_message_projection_order", statements: [
            "DELETE FROM `session_message`;",
            "ALTER TABLE `session_message` ADD COLUMN `seq` integer NOT NULL;",
            "DROP INDEX IF EXISTS `session_message_session_type_time_created_id_idx`;",
            "CREATE INDEX `session_message_session_seq_idx` ON `session_message` (`session_id`,`seq`);",
            "CREATE INDEX `session_message_session_type_seq_idx` ON `session_message` (`session_id`,`type`,`seq`);",
        ])

        // parity: core/src/database/migration/20260603141458_session_input_inbox.ts#default [status=implemented hash=49aa7bd33cf4]
        public static let m_20260603141458_session_input_inbox = sqlMigration(id: "20260603141458_session_input_inbox", statements: [
            "CREATE TABLE `session_input` ( `seq` integer PRIMARY KEY AUTOINCREMENT, `id` text NOT NULL UNIQUE, `session_id` text NOT NULL, `prompt` text NOT NULL, `delivery` text NOT NULL, `promoted_seq` integer, `time_created` integer NOT NULL, CONSTRAINT `fk_session_input_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE );",
            "CREATE INDEX `session_input_session_pending_seq_idx` ON `session_input` (`session_id`,`promoted_seq`,`seq`);",
        ])

        // parity: core/src/database/migration/20260603160727_jittery_ezekiel_stane.ts#default [status=implemented hash=9e4291bdf8f0]
        public static let m_20260603160727_jittery_ezekiel_stane = sqlMigration(id: "20260603160727_jittery_ezekiel_stane", statements: [
            "DROP INDEX IF EXISTS `session_input_session_pending_seq_idx`;",
            "CREATE INDEX IF NOT EXISTS `event_aggregate_type_seq_idx` ON `event` (`aggregate_id`,`type`,`seq`);",
            "CREATE INDEX IF NOT EXISTS `session_input_session_pending_delivery_seq_idx` ON `session_input` (`session_id`,`promoted_seq`,`delivery`,`seq`);",
            "CREATE INDEX IF NOT EXISTS `session_message_session_time_created_id_idx` ON `session_message` (`session_id`,`time_created`,`id`);",
        ])

        // parity: core/src/database/migration/20260604172448_event_sourced_session_input.ts#default [status=implemented hash=765bc72ab634]
        public static let m_20260604172448_event_sourced_session_input = sqlMigration(id: "20260604172448_event_sourced_session_input", statements: [
            "DELETE FROM `session_input`;",
            "DELETE FROM `session_message`;",
            "DELETE FROM `event`;",
            "DELETE FROM `event_sequence`;",
            "UPDATE `session` SET `workspace_id` = NULL;",
            "DELETE FROM `workspace`;",
            "DROP INDEX IF EXISTS `event_aggregate_seq_idx`;",
            "CREATE UNIQUE INDEX `event_aggregate_seq_idx` ON `event` (`aggregate_id`,`seq`);",
            "DROP INDEX IF EXISTS `session_message_session_seq_idx`;",
            "CREATE UNIQUE INDEX `session_message_session_seq_idx` ON `session_message` (`session_id`,`seq`);",
            "PRAGMA foreign_keys=OFF;",
            "CREATE TABLE `__new_session_input` ( `id` text PRIMARY KEY, `session_id` text NOT NULL, `prompt` text NOT NULL, `delivery` text NOT NULL, `admitted_seq` integer NOT NULL, `promoted_seq` integer, `time_created` integer NOT NULL, CONSTRAINT `fk_session_input_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE );",
            "DROP TABLE `session_input`;",
            "ALTER TABLE `__new_session_input` RENAME TO `session_input`;",
            "PRAGMA foreign_keys=ON;",
            "CREATE INDEX `session_input_session_pending_delivery_seq_idx` ON `session_input` (`session_id`,`promoted_seq`,`delivery`,`admitted_seq`);",
            "CREATE UNIQUE INDEX `session_input_session_admitted_seq_idx` ON `session_input` (`session_id`,`admitted_seq`);",
            "CREATE UNIQUE INDEX `session_input_session_promoted_seq_idx` ON `session_input` (`session_id`,`promoted_seq`);",
        ])

        // parity: core/src/database/migration/20260605003541_add_session_context_snapshot.ts#default [status=implemented hash=ee84f9e9a367]
        public static let m_20260605003541_add_session_context_snapshot = sqlMigration(id: "20260605003541_add_session_context_snapshot", statements: [
            "CREATE TABLE `session_context_epoch` ( `session_id` text PRIMARY KEY, `baseline` text NOT NULL, `snapshot` text NOT NULL, `baseline_seq` integer NOT NULL, `replacement_seq` integer, `revision` integer DEFAULT 0 NOT NULL, CONSTRAINT `fk_session_context_epoch_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE );",
        ])

        // parity: core/src/database/migration/20260605042240_add_context_epoch_agent.ts#default [status=implemented hash=35373cd1110d]
        public static let m_20260605042240_add_context_epoch_agent = sqlMigration(id: "20260605042240_add_context_epoch_agent", statements: [
            "ALTER TABLE `session_context_epoch` ADD `agent` text DEFAULT 'build' NOT NULL;",
        ])

        // parity: core/src/database/migration/20260611035744_credential.ts#default [status=implemented hash=237592720243]
        public static let m_20260611035744_credential = sqlMigration(id: "20260611035744_credential", statements: [
            "CREATE TABLE `credential` ( `id` text PRIMARY KEY, `connector_id` text NOT NULL, `method_id` text NOT NULL, `label` text NOT NULL, `value` text NOT NULL, `active` integer DEFAULT false NOT NULL, `time_created` integer NOT NULL, `time_updated` integer NOT NULL );",
            "CREATE UNIQUE INDEX `credential_connector_active_idx` ON `credential` (`connector_id`) WHERE \"credential\".\"active\" = 1;",
        ])

        // parity: core/src/database/migration/20260611192811_lush_chimera.ts#default [status=implemented hash=ea228a58ed8f]
        public static let m_20260611192811_lush_chimera = sqlMigration(id: "20260611192811_lush_chimera", statements: [
            "DROP INDEX IF EXISTS `credential_connector_active_idx`;",
            "DROP TABLE `credential`;",
            "CREATE TABLE `credential` ( `id` text PRIMARY KEY, `integration_id` text, `label` text NOT NULL, `value` text NOT NULL, `connector_id` text, `method_id` text, `active` integer, `time_created` integer NOT NULL, `time_updated` integer NOT NULL );",
        ])

        // parity: core/src/database/migration/20260612174303_project_dir_strategy.ts#default [status=implemented hash=463ab8f313b7]
        public static let m_20260612174303_project_dir_strategy = sqlMigration(id: "20260612174303_project_dir_strategy", statements: [
            "ALTER TABLE `project_directory` ADD `strategy` text;",
            "PRAGMA foreign_keys=OFF;",
            "CREATE TABLE `__new_project_directory` ( `project_id` text NOT NULL, `directory` text NOT NULL, `type` text, `strategy` text, `time_created` integer NOT NULL, CONSTRAINT `project_directory_pk` PRIMARY KEY(`project_id`, `directory`), CONSTRAINT `fk_project_directory_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE );",
            "INSERT INTO `__new_project_directory`(`project_id`, `directory`, `type`, `time_created`) SELECT `project_id`, `directory`, `type`, `time_created` FROM `project_directory`;",
            "DROP TABLE `project_directory`;",
            "ALTER TABLE `__new_project_directory` RENAME TO `project_directory`;",
            "PRAGMA foreign_keys=ON;",
        ])

        // parity: core/src/database/migration/20260622142730_simplify_session_context_epoch.ts#default [status=implemented hash=0fb2b0cb1974]
        public static let m_20260622142730_simplify_session_context_epoch = sqlMigration(id: "20260622142730_simplify_session_context_epoch", statements: [
            "ALTER TABLE `session_context_epoch` DROP COLUMN `agent`;",
            "ALTER TABLE `session_context_epoch` DROP COLUMN `replacement_seq`;",
            "ALTER TABLE `session_context_epoch` DROP COLUMN `revision`;",
        ])

        // parity: core/src/database/migration/20260622170816_reset_v2_session_state.ts#default [status=implemented hash=76e7c33f49bc]
        public static let m_20260622170816_reset_v2_session_state = sqlMigration(id: "20260622170816_reset_v2_session_state", statements: [
            "DELETE FROM `session_context_epoch`;",
            "DELETE FROM `session_input`;",
            "DELETE FROM `session_message`;",
            "DELETE FROM `event`;",
            "DELETE FROM `event_sequence`;",
        ])

        // parity: core/src/database/migration/20260622202450_simplify_session_input.ts#default [status=implemented hash=b5b44303be77]
        public static let m_20260622202450_simplify_session_input = sqlMigration(id: "20260622202450_simplify_session_input", statements: [
            "DELETE FROM `session_context_epoch`;",
            "DELETE FROM `session_input`;",
            "DELETE FROM `session_message`;",
            "DELETE FROM `event`;",
            "DELETE FROM `event_sequence`;",
            "UPDATE `session` SET `workspace_id` = NULL WHERE `workspace_id` IS NOT NULL;",
            "DELETE FROM `workspace`;",
        ])

        // parity: core/src/database/migration/20260804233008_loose_psylocke.ts#default [status=implemented hash=d31fed9ae67f]
        public static let m_20260804233008_loose_psylocke = Migration(id: "20260804233008_loose_psylocke") { tx, _ in
            let prev = try tx.queryOne("SELECT id FROM migration WHERE id = ?", parameters: [.text("20260730195856_optional_session_title")])
            if prev != nil {
                let v1Only = try tx.queryOne("SELECT 1 FROM message WHERE NOT EXISTS (SELECT 1 FROM session_message WHERE session_message.session_id = message.session_id) LIMIT 1")
                if v1Only != nil {
                    throw MigrationError.migrationExecutionFailed(id: "20260804233008_loose_psylocke", message: "Previous V2 database contains V1-only session history")
                }
                _ = try tx.execute("DROP INDEX IF EXISTS `session_project_idx`;")
                _ = try tx.execute("DROP INDEX IF EXISTS `session_workspace_idx`;")
                _ = try tx.execute("DROP INDEX IF EXISTS `session_parent_idx`;")
                _ = try tx.execute("DROP INDEX IF EXISTS `session_time_suspended_idx`;")
                _ = try tx.execute("ALTER TABLE `session` RENAME TO `session_v2`;")
                _ = try tx.execute("CREATE INDEX `session_v2_project_idx` ON `session_v2` (`project_id`);")
                _ = try tx.execute("CREATE INDEX `session_v2_workspace_idx` ON `session_v2` (`workspace_id`);")
                _ = try tx.execute("CREATE INDEX `session_v2_parent_idx` ON `session_v2` (`parent_id`);")
                _ = try tx.execute("CREATE INDEX `session_v2_time_suspended_idx` ON `session_v2` (`time_suspended`) WHERE \"session_v2\".\"time_suspended\" is not null;")
                _ = try tx.execute("DROP TABLE IF EXISTS `data_migration`;")
                _ = try tx.execute("DROP TABLE IF EXISTS `session_context_epoch`;")
                _ = try tx.execute("DROP TABLE IF EXISTS `session_input`;")
                return
            }
                _ = try tx.execute("CREATE TABLE IF NOT EXISTS `kv` ( `key` text PRIMARY KEY, `value` text NOT NULL, `time_created` integer NOT NULL, `time_updated` integer NOT NULL );")
                _ = try tx.execute("CREATE TABLE IF NOT EXISTS `instruction_blob` ( `hash` text PRIMARY KEY, `value` text );")
                _ = try tx.execute("CREATE TABLE IF NOT EXISTS `instruction_entry` ( `session_id` text NOT NULL, `key` text NOT NULL, `value` text, `removed` integer DEFAULT false NOT NULL, `time_created` integer NOT NULL, `time_updated` integer NOT NULL, CONSTRAINT `instruction_entry_pk` PRIMARY KEY(`session_id`, `key`), CONSTRAINT `fk_instruction_entry_session_id_session_v2_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session_v2`(`id`) ON DELETE CASCADE );")
                _ = try tx.execute("CREATE TABLE IF NOT EXISTS `instruction_state` ( `session_id` text PRIMARY KEY, `epoch_start` integer NOT NULL, `through_seq` integer NOT NULL, `initial_values` text NOT NULL, `current_values` text NOT NULL, CONSTRAINT `fk_instruction_state_session_id_session_v2_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session_v2`(`id`) ON DELETE CASCADE );")
                _ = try tx.execute("CREATE TABLE IF NOT EXISTS `session_pending` ( `id` text PRIMARY KEY, `session_id` text NOT NULL, `type` text NOT NULL, `data` text NOT NULL, `delivery` text, `admitted_seq` integer NOT NULL, `time_created` integer NOT NULL, CONSTRAINT `fk_session_pending_session_id_session_v2_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session_v2`(`id`) ON DELETE CASCADE );")
                _ = try tx.execute("CREATE TABLE IF NOT EXISTS `session_v2` ( `id` text PRIMARY KEY, `project_id` text NOT NULL, `workspace_id` text, `parent_id` text, `fork_session_id` text, `fork_boundary` text, `slug` text NOT NULL, `directory` text NOT NULL, `path` text, `title` text, `version` text NOT NULL, `share_url` text, `summary_additions` integer, `summary_deletions` integer, `summary_files` integer, `summary_diffs` text, `metadata` text, `cost` real DEFAULT 0 NOT NULL, `tokens_input` integer DEFAULT 0 NOT NULL, `tokens_output` integer DEFAULT 0 NOT NULL, `tokens_reasoning` integer DEFAULT 0 NOT NULL, `tokens_cache_read` integer DEFAULT 0 NOT NULL, `tokens_cache_write` integer DEFAULT 0 NOT NULL, `revert` text, `permission` text, `agent` text, `model` text, `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `time_compacting` integer, `time_archived` integer, `time_suspended` integer, CONSTRAINT `fk_session_v2_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE );")
                _ = try tx.execute("ALTER TABLE `event` ADD `created` integer DEFAULT 0 NOT NULL;")
                _ = try tx.execute("CREATE TABLE IF NOT EXISTS `__new_session_message` ( `id` text PRIMARY KEY, `session_id` text NOT NULL, `type` text NOT NULL, `seq` integer NOT NULL, `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `data` text NOT NULL, CONSTRAINT `fk_session_message_session_id_session_v2_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session_v2`(`id`) ON DELETE CASCADE );")
                _ = try tx.execute("DROP TABLE `session_message`;")
                _ = try tx.execute("ALTER TABLE `__new_session_message` RENAME TO `session_message`;")
                _ = try tx.execute("CREATE UNIQUE INDEX `session_message_session_seq_idx` ON `session_message` (`session_id`,`seq`);")
                _ = try tx.execute("CREATE INDEX `session_message_session_type_seq_idx` ON `session_message` (`session_id`,`type`,`seq`);")
                _ = try tx.execute("CREATE INDEX `session_message_session_time_created_id_idx` ON `session_message` (`session_id`,`time_created`,`id`);")
                _ = try tx.execute("CREATE INDEX `session_message_time_created_idx` ON `session_message` (`time_created`);")
                _ = try tx.execute("CREATE INDEX `session_pending_session_delivery_seq_idx` ON `session_pending` (`session_id`,`delivery`,`admitted_seq`);")
                _ = try tx.execute("CREATE UNIQUE INDEX `session_pending_session_compaction_idx` ON `session_pending` (`session_id`) WHERE \"session_pending\".\"type\" = 'compaction';")
                _ = try tx.execute("CREATE UNIQUE INDEX `session_pending_session_admitted_seq_idx` ON `session_pending` (`session_id`,`admitted_seq`);")
                _ = try tx.execute("CREATE INDEX `session_v2_project_idx` ON `session_v2` (`project_id`);")
                _ = try tx.execute("CREATE INDEX `session_v2_workspace_idx` ON `session_v2` (`workspace_id`);")
                _ = try tx.execute("CREATE INDEX `session_v2_parent_idx` ON `session_v2` (`parent_id`);")
                _ = try tx.execute("CREATE INDEX `session_v2_time_suspended_idx` ON `session_v2` (`time_suspended`) WHERE \"session_v2\".\"time_suspended\" is not null;")
                _ = try tx.execute("DROP TABLE `data_migration`;")
                _ = try tx.execute("DROP TABLE `session_context_epoch`;")
                _ = try tx.execute("DROP TABLE `session_input`;")
        }

        // parity: core/src/database/migration/20260805200742_import_legacy_credentials.ts#default [status=implemented hash=cfb17b818ba5]
        public static let m_20260805200742_import_legacy_credentials = Migration(id: "20260805200742_import_legacy_credentials") { tx, ctx in
            if let dir = ctx.dataDirectory {
                try importLegacyCredentialsSync(tx: tx, filepath: "\(dir)/auth.json")
            }
        }

        // parity: core/src/database/migration/20260808023530_workspace_domain.ts#default [status=implemented hash=deae1995d459]
        public static let m_20260808023530_workspace_domain = sqlMigration(id: "20260808023530_workspace_domain", statements: [
            "DROP TABLE `workspace`;",
            "CREATE TABLE `workspace` ( `id` text PRIMARY KEY, `provider` text NOT NULL, `binding` text NOT NULL, `created_at` integer NOT NULL, `last_used_at` integer NOT NULL );",
        ])

        // parity: core/src/database/migration/20260811161259_execution_claim_attempts.ts#default [status=implemented hash=d044554739d5]
        public static let m_20260811161259_execution_claim_attempts = sqlMigration(id: "20260811161259_execution_claim_attempts", statements: [
            "ALTER TABLE `session_v2` ADD `resume_attempts` integer DEFAULT 0 NOT NULL;",
        ])

        // parity: core/src/database/migration/20260812181746_session_inbox.ts#default [status=implemented hash=ccc21c7cf798]
        public static let m_20260812181746_session_inbox = sqlMigration(id: "20260812181746_session_inbox", statements: [
            "CREATE TABLE `session_inbox` ( `id` text PRIMARY KEY, `session_id` text NOT NULL, `type` text NOT NULL, `payload` text NOT NULL, `delivery` text NOT NULL, `enqueued_seq` integer NOT NULL, `time_created` integer NOT NULL, CONSTRAINT `fk_session_inbox_session_id_session_v2_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session_v2`(`id`) ON DELETE CASCADE );",
            "CREATE INDEX `session_inbox_session_delivery_seq_idx` ON `session_inbox` (`session_id`,`delivery`,`enqueued_seq`);",
            "CREATE UNIQUE INDEX `session_inbox_session_enqueued_seq_idx` ON `session_inbox` (`session_id`,`enqueued_seq`);",
        ])

        // parity: core/src/database/migration/20260812213948_worktree.ts#default [status=implemented hash=3b9beb9399ff]
        public static let m_20260812213948_worktree = sqlMigration(id: "20260812213948_worktree", statements: [
            "CREATE TABLE `worktree` ( `project_id` text NOT NULL, `directory` text NOT NULL, `strategy` text, `time_created` integer NOT NULL, CONSTRAINT `worktree_pk` PRIMARY KEY(`project_id`, `directory`), CONSTRAINT `fk_worktree_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE );",
            "INSERT INTO `worktree` (`project_id`, `directory`, `strategy`, `time_created`) SELECT `project_id`, `directory`, CASE WHEN `strategy` = 'git_worktree' THEN 'git' WHEN `strategy` IS NOT NULL THEN `strategy` WHEN `type` = 'git_worktree' THEN 'git' END, `time_created` FROM `project_directory`;",
        ])

        // parity: core/src/database/migration/20260819222447_session_viewed_state.ts#default [status=implemented hash=08046bd106a7]
        public static let m_20260819222447_session_viewed_state = sqlMigration(id: "20260819222447_session_viewed_state", statements: [
            "ALTER TABLE `session_v2` ADD `time_idle` integer;",
            "ALTER TABLE `session_v2` ADD `time_viewed` integer;",
            "ALTER TABLE `session_v2` ADD `idle_outcome` text;",
        ])

        // parity: core/src/database/migration/20260823191254_nullable_workspace_binding.ts#default [status=implemented hash=9f2423d14eb8]
        public static let m_20260823191254_nullable_workspace_binding = sqlMigration(id: "20260823191254_nullable_workspace_binding", foreignKeys: false, statements: [
            "CREATE TABLE `__new_workspace` ( `id` text PRIMARY KEY, `provider` text NOT NULL, `binding` text, `created_at` integer NOT NULL, `last_used_at` integer NOT NULL );",
            "INSERT INTO `__new_workspace`(`id`, `provider`, `binding`, `created_at`, `last_used_at`) SELECT `id`, `provider`, `binding`, `created_at`, `last_used_at` FROM `workspace`;",
            "DROP TABLE `workspace`;",
            "ALTER TABLE `__new_workspace` RENAME TO `workspace`;",
        ])

        // parity: core/src/database/migration/20260910120000_clear_v1_session_permission.ts#default [status=implemented hash=9c34e6ec771f]
        public static let m_20260910120000_clear_v1_session_permission = sqlMigration(id: "20260910120000_clear_v1_session_permission", statements: [
            "UPDATE `session_v2` SET `permission` = NULL;",
        ])

        // parity: core/src/database/migration/20260923013825_project_time_active.ts#default [status=implemented hash=e8f6dfbef949]
        public static let m_20260923013825_project_time_active = sqlMigration(id: "20260923013825_project_time_active", statements: [
            "ALTER TABLE `project` ADD `time_active` integer DEFAULT 0 NOT NULL;",
            "UPDATE `project` SET `time_active` = `time_updated`;",
        ])

        // parity: core/src/database/migration/20261007190000_azure_cli_external_credential.ts#default [status=implemented hash=7bc59276dc82]
        public static let m_20261007190000_azure_cli_external_credential = sqlMigration(id: "20261007190000_azure_cli_external_credential", statements: [
            "UPDATE `credential` SET `value` = json_remove(json_set(`value`, '$.type', 'external'), '$.access', '$.refresh', '$.expires') WHERE `integration_id` = 'azure' AND json_extract(`value`, '$.type') = 'oauth' AND json_extract(`value`, '$.methodID') = 'azure-cli'",
        ])

        // parity: core/src/database/migration/20261010180456_project_time_archived.ts#default [status=implemented hash=160fda157558]
        public static let m_20261010180456_project_time_archived = sqlMigration(id: "20261010180456_project_time_archived", statements: [
            "ALTER TABLE `project` ADD `time_archived` integer;",
        ])

        // parity: core/src/database/migration/20261024002554_session_allowance.ts#default [status=implemented hash=1e35c193ad16]
        public static let m_20261024002554_session_allowance = sqlMigration(id: "20261024002554_session_allowance", statements: [
            "ALTER TABLE `session_v2` ADD `allowance` real DEFAULT 0 NOT NULL;",
        ])

        // parity: core/src/database/migration/20261024175301_drop_session_allowance.ts#default [status=implemented hash=ce20d9b4bb1d]
        public static let m_20261024175301_drop_session_allowance = sqlMigration(id: "20261024175301_drop_session_allowance", statements: [
            "ALTER TABLE `session_v2` DROP COLUMN `allowance`;",
        ])

        // parity: core/src/database/migration/20261025123711_blob.ts#default [status=implemented hash=343b421d87d8]
        public static let m_20261025123711_blob = sqlMigration(id: "20261025123711_blob", statements: [
            "CREATE TABLE `blob_ref` ( `session_id` text NOT NULL, `message_id` text NOT NULL, `hash` text NOT NULL, `seq` integer NOT NULL, CONSTRAINT `blob_ref_pk` PRIMARY KEY(`session_id`, `message_id`, `hash`), CONSTRAINT `fk_blob_ref_session_id_session_v2_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session_v2`(`id`) ON DELETE CASCADE, CONSTRAINT `fk_blob_ref_hash_blob_hash_fk` FOREIGN KEY (`hash`) REFERENCES `blob`(`hash`) ON DELETE CASCADE );",
            "CREATE TABLE `blob` ( `hash` text PRIMARY KEY, `mime` text NOT NULL, `bytes` integer NOT NULL, `width` integer, `height` integer, `data` blob NOT NULL, `time_created` integer NOT NULL );",
            "CREATE INDEX `blob_ref_hash_idx` ON `blob_ref` (`hash`);",
            "CREATE INDEX `blob_ref_session_seq_idx` ON `blob_ref` (`session_id`,`seq`);",
        ])

        // parity: core/src/database/migration/20261025154125_drop_session_pending.ts#default [status=implemented hash=ee41904f6886]
        public static let m_20261025154125_drop_session_pending = sqlMigration(id: "20261025154125_drop_session_pending", statements: [
            "DROP INDEX IF EXISTS `session_pending_session_delivery_seq_idx`;",
            "DROP INDEX IF EXISTS `session_pending_session_compaction_idx`;",
            "DROP INDEX IF EXISTS `session_pending_session_admitted_seq_idx`;",
            "DROP TABLE IF EXISTS `session_pending`;",
        ])

        // parity: core/src/database/migration/20261026223005_schedule.ts#default [status=implemented hash=f4fa0915ac9d]
        public static let m_20261026223005_schedule = sqlMigration(id: "20261026223005_schedule", statements: [
            "CREATE TABLE `schedule` ( `id` text PRIMARY KEY, `session_id` text, `name` text, `action` text NOT NULL, `when` text NOT NULL, `tz` text NOT NULL, `status` text DEFAULT 'active' NOT NULL, `next_due_at` integer, `ends_at` integer, `remaining_runs` integer, `run_count` integer DEFAULT 0 NOT NULL, `last_fired_at` integer, `last_message_id` text, `last_outcome` text, `retry_at` integer, `time_created` integer NOT NULL, `time_updated` integer NOT NULL, CONSTRAINT `fk_schedule_session_id_session_v2_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session_v2`(`id`) ON DELETE CASCADE );",
            "CREATE INDEX `schedule_session_idx` ON `schedule` (`session_id`);",
            "CREATE INDEX `schedule_due_idx` ON `schedule` (`next_due_at`) WHERE \"schedule\".\"status\" = 'active' and \"schedule\".\"next_due_at\" is not null;",
        ])

        // parity: core/src/database/migration/20261029002625_session_part.ts#default [status=implemented hash=a298bc13f07f]
        public static let m_20261029002625_session_part = sqlMigration(id: "20261029002625_session_part", statements: [
            "CREATE TABLE `session_part` ( `message_id` text NOT NULL, `session_id` text NOT NULL, `ordinal` integer NOT NULL, `type` text NOT NULL, `call_id` text, `time_created` integer NOT NULL, `time_updated` integer NOT NULL, `data` text NOT NULL, CONSTRAINT `session_part_pk` PRIMARY KEY(`message_id`, `ordinal`), CONSTRAINT `fk_session_part_message_id_session_message_id_fk` FOREIGN KEY (`message_id`) REFERENCES `session_message`(`id`) ON DELETE CASCADE, CONSTRAINT `fk_session_part_session_id_session_v2_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session_v2`(`id`) ON DELETE CASCADE );",
            "CREATE INDEX `session_part_session_message_idx` ON `session_part` (`session_id`,`message_id`,`ordinal`);",
        ])

        // parity: core/src/database/migration/20261029073502_session_time_busy.ts#default [status=implemented hash=2ebec163b715]
        public static let m_20261029073502_session_time_busy = sqlMigration(id: "20261029073502_session_time_busy", statements: [
            "ALTER TABLE `session_v2` ADD `time_busy` integer;",
        ])

        // parity: core/src/database/migration/20261029165540_schedule_checks.ts#default [status=implemented hash=84bf08bf3a6e]
        public static let m_20261029165540_schedule_checks = sqlMigration(id: "20261029165540_schedule_checks", statements: [
            "ALTER TABLE `schedule` ADD `check` text;",
            "ALTER TABLE `schedule` ADD `checks` integer DEFAULT 0 NOT NULL;",
            "ALTER TABLE `schedule` ADD `failures` integer DEFAULT 0 NOT NULL;",
            "ALTER TABLE `schedule` ADD `state` text;",
        ])

        // parity: core/src/database/migration/20261030054400_job.ts#default [status=implemented hash=14101286023a]
        public static let m_20261030054400_job = sqlMigration(id: "20261030054400_job", statements: [
            "CREATE TABLE `job` ( `notification_id` text PRIMARY KEY, `id` text NOT NULL, `session_id` text NOT NULL, `child_session_id` text, `kind` text NOT NULL, `title` text, `status` text NOT NULL, `output` text, `error` text, `recovery` text NOT NULL, `time_created` integer NOT NULL, `time_updated` integer NOT NULL );",
            "CREATE INDEX `job_session_idx` ON `job` (`session_id`);",
            "CREATE INDEX `job_child_session_idx` ON `job` (`child_session_id`);",
            "CREATE INDEX `job_id_idx` ON `job` (`id`);",
            "INSERT OR IGNORE INTO `job` ( `notification_id`, `id`, `session_id`, `child_session_id`, `kind`, `title`, `status`, `output`, `error`, `recovery`, `time_created`, `time_updated` ) SELECT json_extract(`value`, '$.notificationID'), json_extract(`value`, '$.id'), COALESCE(json_extract(`value`, '$.recovery.sessionID'), json_extract(`value`, '$.recovery.parentSessionID')), json_extract(`value`, '$.recovery.childSessionID'), json_extract(`value`, '$.recovery.kind'), COALESCE( json_extract(`value`, '$.recovery.command'), json_extract(`value`, '$.recovery.description'), json_extract(`value`, '$.recovery.path') ), json_extract(`value`, '$.status'), json_extract(`value`, '$.output'), json_extract(`value`, '$.error'), json_extract(`value`, '$.recovery'), `time_created`, `time_updated` FROM `kv` WHERE `key` LIKE 'job.background/%' AND json_extract(`value`, '$.notificationID') IS NOT NULL AND json_extract(`value`, '$.id') IS NOT NULL AND COALESCE(json_extract(`value`, '$.recovery.sessionID'), json_extract(`value`, '$.recovery.parentSessionID')) IS NOT NULL;",
            "DELETE FROM `kv` WHERE `key` LIKE 'job.background/%';",
        ])

        // parity: core/src/database/migration/20261116043204_automation.ts#default [status=implemented hash=0a3db3bdcff0]
        public static let m_20261116043204_automation = sqlMigration(id: "20261116043204_automation", statements: [
            "CREATE TABLE `automation` ( `id` text PRIMARY KEY, `project_id` text NOT NULL, `session_id` text, `directory` text NOT NULL, `name` text NOT NULL, `trigger` text NOT NULL, `tz` text NOT NULL, `action` text NOT NULL, `status` text DEFAULT 'active' NOT NULL, `next_due_at` integer, `expires_at` integer, `run_count` integer DEFAULT 0 NOT NULL, `failures` integer DEFAULT 0 NOT NULL, `last_run_at` integer, `last_message_id` text, `last_outcome` text, `last_output` text, `retry_at` integer, `state` text, `time_created` integer NOT NULL, `time_updated` integer NOT NULL );",
            "DROP INDEX IF EXISTS `schedule_session_idx`;",
            "DROP INDEX IF EXISTS `schedule_due_idx`;",
            "CREATE INDEX `automation_project_idx` ON `automation` (`project_id`);",
            "CREATE INDEX `automation_session_idx` ON `automation` (`session_id`);",
            "CREATE INDEX `automation_due_idx` ON `automation` (`next_due_at`) WHERE \"automation\".\"status\" = 'active' and \"automation\".\"next_due_at\" is not null;",
            "INSERT INTO `automation` ( `id`, `project_id`, `session_id`, `directory`, `name`, `trigger`, `tz`, `action`, `status`, `next_due_at`, `expires_at`, `run_count`, `last_run_at`, `last_message_id`, `last_outcome`, `retry_at`, `time_created`, `time_updated` ) SELECT 'aut_' || substr(s.`id`, 5), v.`project_id`, s.`session_id`, v.`directory`, coalesce(s.`name`, substr(json_extract(s.`action`, '$.prompt'), 1, 60)), CASE json_extract(s.`when`, '$.type') WHEN 'in' THEN json_object('type', 'at', 'at', strftime('%Y-%m-%dT%H:%M:%fZ', s.`next_due_at` / 1000.0, 'unixepoch')) ELSE s.`when` END, s.`tz`, json_object('type', 'prompt', 'prompt', json_extract(s.`action`, '$.prompt'), 'to', json_object('session', s.`session_id`)), s.`status`, s.`next_due_at`, s.`ends_at`, s.`run_count`, s.`last_fired_at`, s.`last_message_id`, s.`last_outcome`, s.`retry_at`, s.`time_created`, s.`time_updated` FROM `schedule` s JOIN `session_v2` v ON v.`id` = s.`session_id` WHERE s.`status` IN ('active', 'paused') AND s.`check` IS NULL AND s.`remaining_runs` IS NULL AND s.`next_due_at` IS NOT NULL;",
            "DROP TABLE `schedule`;",
        ])

        // parity: core/src/database/migration/20261116181958_automation_event_position.ts#default [status=implemented hash=f9a91681b854]
        public static let m_20261116181958_automation_event_position = sqlMigration(id: "20261116181958_automation_event_position", statements: [
            "ALTER TABLE `automation` ADD `event_position` text;",
        ])

        // parity: core/src/database/migration/20261116213417_automation_active_index.ts#default [status=implemented hash=0395c6b1f9e3]
        public static let m_20261116213417_automation_active_index = sqlMigration(id: "20261116213417_automation_active_index", statements: [
            "DROP INDEX IF EXISTS `automation_due_idx`;",
            "CREATE INDEX `automation_active_idx` ON `automation` (`next_due_at`) WHERE \"automation\".\"status\" = 'active';",
        ])

        // parity: core/src/database/migration/20261119211416_machine.ts#default [status=implemented hash=9a1c9ba070b8]
        public static let m_20261119211416_machine = sqlMigration(id: "20261119211416_machine", statements: [
            "CREATE TABLE `machine` ( `id` text PRIMARY KEY, `time_created` integer NOT NULL );",
        ])

        // parity: core/src/database/migration/20261120004954_machine-key.ts#default [status=implemented hash=9daf45dbd4a2]
        public static let m_20261120004954_machine_key = sqlMigration(id: "20261120004954_machine-key", statements: [
            "ALTER TABLE `machine` ADD `key` text;",
            "CREATE UNIQUE INDEX `machine_key_idx` ON `machine` (`key`);",
        ])

        public static let all: [Migration] = [
            m_20260127222353_familiar_lady_ursula,
            m_20260211171708_add_project_commands,
            m_20260213144116_wakeful_the_professor,
            m_20260225215848_workspace,
            m_20260227213759_add_session_workspace_id,
            m_20260228203230_blue_harpoon,
            m_20260303231226_add_workspace_fields,
            m_20260309230000_move_org_to_state,
            m_20260312043431_session_message_cursor,
            m_20260323234822_events,
            m_20260410174513_workspace_name,
            m_20260413175956_chief_energizer,
            m_20260423070820_add_icon_url_override,
            m_20260427172553_slow_nightmare,
            m_20260428004200_add_session_path,
            m_20260501142318_next_venus,
            m_20260504145000_add_sync_owner,
            m_20260507164347_add_workspace_time,
            m_20260510033149_session_usage,
            m_20260511000411_data_migration_state,
            m_20260511173437_session_metadata,
            m_20260601010001_normalize_storage_paths,
            m_20260601202201_amazing_prowler,
            m_20260602002951_lowly_union_jack,
            m_20260602182828_add_project_directories,
            m_20260603001617_session_message_projection_indexes,
            m_20260603040000_session_message_projection_order,
            m_20260603141458_session_input_inbox,
            m_20260603160727_jittery_ezekiel_stane,
            m_20260604172448_event_sourced_session_input,
            m_20260605003541_add_session_context_snapshot,
            m_20260605042240_add_context_epoch_agent,
            m_20260611035744_credential,
            m_20260611192811_lush_chimera,
            m_20260612174303_project_dir_strategy,
            m_20260622142730_simplify_session_context_epoch,
            m_20260622170816_reset_v2_session_state,
            m_20260622202450_simplify_session_input,
            m_20260804233008_loose_psylocke,
            m_20260805200742_import_legacy_credentials,
            m_20260808023530_workspace_domain,
            m_20260811161259_execution_claim_attempts,
            m_20260812181746_session_inbox,
            m_20260812213948_worktree,
            m_20260819222447_session_viewed_state,
            m_20260823191254_nullable_workspace_binding,
            m_20260910120000_clear_v1_session_permission,
            m_20260923013825_project_time_active,
            m_20261007190000_azure_cli_external_credential,
            m_20261010180456_project_time_archived,
            m_20261024002554_session_allowance,
            m_20261024175301_drop_session_allowance,
            m_20261025123711_blob,
            m_20261025154125_drop_session_pending,
            m_20261026223005_schedule,
            m_20261029002625_session_part,
            m_20261029073502_session_time_busy,
            m_20261029165540_schedule_checks,
            m_20261030054400_job,
            m_20261116043204_automation,
            m_20261116181958_automation_event_position,
            m_20261116213417_automation_active_index,
            m_20261119211416_machine,
            m_20261120004954_machine_key,
        ]
    }
}
