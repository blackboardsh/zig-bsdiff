#!/usr/bin/env node

import { createHash, createHmac } from "node:crypto";
import {
	existsSync,
	readFileSync,
	readdirSync,
	statSync,
	writeFileSync,
} from "node:fs";
import { basename, join, resolve } from "node:path";

const TARGETS = {
	"zig-bsdiff": [
		"darwin-arm64",
		"darwin-x64",
		"linux-arm64",
		"linux-x64",
		"win32-x64",
	],
	"zig-zstd": [
		"darwin-arm64",
		"darwin-x64",
		"linux-arm64",
		"linux-x64",
		"win32-x64",
	],
	"zig-asar": [
		"darwin-arm64",
		"darwin-x64",
		"linux-arm64",
		"linux-x64",
		"win32-arm64",
		"win32-x64",
	],
	"electrobun-dawn": [
		"darwin-arm64",
		"darwin-x64",
		"linux-arm64",
		"linux-x64",
		"win32-x64",
	],
};

const rootDir = process.cwd();
const packageJson = JSON.parse(
	readFileSync(join(rootDir, "package.json"), "utf8"),
);
const product = packageJson.name;
const version = packageJson.version;
const artifactsArg = process.argv.find((value) =>
	value.startsWith("--artifacts="),
);
const artifactsDir = resolve(
	rootDir,
	artifactsArg?.slice("--artifacts=".length) ?? "artifacts",
);
const dryRun =
	process.argv.includes("--dry-run") || process.env.R2_DRY_RUN === "1";
const publicBaseUrl = (
	process.env.R2_PUBLIC_BASE_URL ??
	"https://electrobun-artifacts.blackboard.sh"
).replace(/\/+$/, "");
const bucket = process.env.R2_BUCKET ?? "electrobun-artifacts";

function fail(message) {
	console.error(`${product} publish: ${message}`);
	process.exit(1);
}

if (!(product in TARGETS)) fail(`unsupported product ${product}`);
if (!existsSync(artifactsDir)) {
	fail(`artifacts directory does not exist: ${artifactsDir}`);
}

const releaseTag =
	process.env.RELEASE_TAG ??
	(process.env.GITHUB_REF_TYPE === "tag"
		? process.env.GITHUB_REF_NAME
		: `v${version}`);
if (releaseTag !== `v${version}`) {
	fail(`release tag ${releaseTag} does not match package version ${version}`);
}

function sha256(value) {
	return createHash("sha256").update(value).digest("hex");
}

function hmac(key, value) {
	return createHmac("sha256", key).update(value).digest();
}

function awsEncode(value) {
	return encodeURIComponent(value).replace(/[!'()*]/g, (character) =>
		`%${character.charCodeAt(0).toString(16).toUpperCase()}`,
	);
}

function signedPut(config, key, body, contentType, now = new Date()) {
	const endpoint = new URL(
		`https://${config.accountId}.r2.cloudflarestorage.com`,
	);
	const canonicalUri = `/${[bucket, ...key.split("/")].map(awsEncode).join("/")}`;
	const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, "");
	const date = amzDate.slice(0, 8);
	const payloadHash = sha256(body);
	const cacheControl = "public, max-age=31536000, immutable";
	const canonicalHeaders = [
		`cache-control:${cacheControl}`,
		`content-type:${contentType}`,
		`host:${endpoint.host}`,
		`x-amz-content-sha256:${payloadHash}`,
		`x-amz-date:${amzDate}`,
		"",
	].join("\n");
	const signedHeaders =
		"cache-control;content-type;host;x-amz-content-sha256;x-amz-date";
	const canonicalRequest = [
		"PUT",
		canonicalUri,
		"",
		canonicalHeaders,
		signedHeaders,
		payloadHash,
	].join("\n");
	const scope = `${date}/auto/s3/aws4_request`;
	const stringToSign = [
		"AWS4-HMAC-SHA256",
		amzDate,
		scope,
		sha256(canonicalRequest),
	].join("\n");
	const dateKey = hmac(Buffer.from(`AWS4${config.secretAccessKey}`), date);
	const regionKey = hmac(dateKey, "auto");
	const serviceKey = hmac(regionKey, "s3");
	const signingKey = hmac(serviceKey, "aws4_request");
	const signature = createHmac("sha256", signingKey)
		.update(stringToSign)
		.digest("hex");

	return {
		url: new URL(canonicalUri, endpoint).href,
		headers: {
			Authorization: `AWS4-HMAC-SHA256 Credential=${config.accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
			"Cache-Control": cacheControl,
			"Content-Type": contentType,
			"x-amz-content-sha256": payloadHash,
			"x-amz-date": amzDate,
		},
	};
}

async function putObject(config, key, body, contentType) {
	if (dryRun) {
		console.log(`dry-run PUT ${key} (${body.length} bytes)`);
		return;
	}
	const request = signedPut(config, key, body, contentType);
	const response = await fetch(request.url, {
		method: "PUT",
		headers: request.headers,
		body,
	});
	if (!response.ok) {
		throw new Error(
			`R2 upload failed for ${key}: ${response.status} ${await response.text()}`,
		);
	}
	console.log(`uploaded ${key}`);
}

async function publicText(key) {
	const response = await fetch(`${publicBaseUrl}/${key}`, {
		cache: "no-store",
	});
	if (response.status === 404) return null;
	if (!response.ok) {
		throw new Error(`failed to inspect ${key}: HTTP ${response.status}`);
	}
	return response.text();
}

function walk(directory) {
	const files = [];
	for (const entry of readdirSync(directory, { withFileTypes: true })) {
		const path = join(directory, entry.name);
		if (entry.isDirectory()) files.push(...walk(path));
		else if (entry.isFile()) files.push(path);
	}
	return files;
}

const expectedNames = TARGETS[product].map(
	(target) => `${product}-${target}.tar.gz`,
);
const archiveByName = new Map(
	walk(artifactsDir)
		.filter((path) => path.endsWith(".tar.gz"))
		.map((path) => [basename(path), path]),
);
const missing = expectedNames.filter((name) => !archiveByName.has(name));
const unexpected = [...archiveByName.keys()].filter(
	(name) => !expectedNames.includes(name),
);
if (missing.length > 0) fail(`incomplete matrix; missing ${missing.join(", ")}`);
if (unexpected.length > 0) {
	fail(`unexpected artifacts: ${unexpected.join(", ")}`);
}

const artifacts = expectedNames.map((name) => {
	const path = archiveByName.get(name);
	const body = readFileSync(path);
	const checksum = sha256(body);
	const checksumBody = Buffer.from(`${checksum}  ${name}\n`);
	writeFileSync(`${path}.sha256`, checksumBody);
	return {
		name,
		body,
		checksum,
		checksumBody,
		size: statSync(path).size,
	};
});

const config = {
	accountId: process.env.R2_ACCOUNT_ID,
	accessKeyId: process.env.R2_ACCESS_KEY_ID,
	secretAccessKey: process.env.R2_SECRET_ACCESS_KEY,
};
if (!dryRun) {
	const missingConfig = Object.entries(config)
		.filter(([, value]) => !value)
		.map(([name]) => name);
	if (missingConfig.length > 0) {
		fail(`missing R2 configuration: ${missingConfig.join(", ")}`);
	}
}

const releasePrefix = `${product}/releases/${version}`;
for (const artifact of artifacts) {
	const key = `${releasePrefix}/${artifact.name}`;
	const checksumKey = `${key}.sha256`;
	const existingChecksum = await publicText(checksumKey);
	if (existingChecksum !== null) {
		const recorded = existingChecksum.trim().split(/\s+/, 1)[0];
		if (recorded !== artifact.checksum) {
			fail(`immutable artifact collision for ${key}`);
		}
		console.log(`already published ${key}`);
		continue;
	}
	await putObject(config, key, artifact.body, "application/gzip");
	await putObject(
		config,
		checksumKey,
		artifact.checksumBody,
		"text/plain; charset=utf-8",
	);
}

const manifestKey = `${releasePrefix}/manifest.json`;
const manifest = {
	schemaVersion: 1,
	product,
	version,
	tag: releaseTag,
	revision: process.env.GITHUB_SHA ?? null,
	source: `https://github.com/${process.env.GITHUB_REPOSITORY ?? `blackboardsh/${product}`}/releases/tag/${releaseTag}`,
	publishedAt: new Date().toISOString(),
	artifacts: Object.fromEntries(
		artifacts.map((artifact) => [
			artifact.name.slice(`${product}-`.length, -".tar.gz".length),
			{
				url: `${publicBaseUrl}/${releasePrefix}/${artifact.name}`,
				sha256: artifact.checksum,
				size: artifact.size,
			},
		]),
	),
};
const existingManifest = await publicText(manifestKey);
if (existingManifest !== null) {
	const parsed = JSON.parse(existingManifest);
	for (const [target, artifact] of Object.entries(manifest.artifacts)) {
		if (parsed.artifacts?.[target]?.sha256 !== artifact.sha256) {
			fail(`immutable manifest collision for ${manifestKey}`);
		}
	}
	console.log(`already published ${manifestKey}`);
} else {
	await putObject(
		config,
		manifestKey,
		Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`),
		"application/json; charset=utf-8",
	);
}

console.log(`published ${product} ${version} (${artifacts.length} targets)`);
