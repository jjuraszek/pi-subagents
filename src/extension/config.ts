import * as fs from "node:fs";
import * as path from "node:path";
import type { ExtensionConfig } from "../shared/types.ts";
import { getAgentDir } from "../shared/utils.ts";

export function loadConfig(): ExtensionConfig {
	const configPath = path.join(getAgentDir(), "extensions", "pi-cohort", "config.json");
	try {
		if (fs.existsSync(configPath)) {
			return JSON.parse(fs.readFileSync(configPath, "utf-8")) as ExtensionConfig;
		}
	} catch (error) {
		console.error(`Failed to load pi-cohort config from '${configPath}':`, error);
	}
	return {};
}
