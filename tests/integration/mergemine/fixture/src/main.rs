//! Merge-mining submission fixture (pithead #2586, row V6 of #1129).
//!
//! Built inside Tari's own workspace at the pinned tag (see ../Dockerfile), so every check below is
//! Tari's code, not an imitation of it:
//!
//! * `templates <dir> <difficulty>` writes the replies the recording node (../fake_tari_node.py)
//!   serves to P2Pool: one mainnet-shaped RandomXM template per fork-boundary height, its merge
//!   mining hash computed by Tari, `tari_unique_id` = the mainnet genesis hash.
//! * `validate <dir> <difficulty>` reads the `SubmitBlock` requests P2Pool sent and runs Tari's
//!   own `monero_randomx_difficulty` (payload decode in the format the height requires, merge
//!   mining tag, aux-chain proof, coinbase merkle root, RandomX) under MainNet consensus constants.
//!
//! The one test-only deviation: the achieved difficulty is compared with the template's test
//! difficulty, not with MainNet's target. Both numbers are printed.
use std::{fs, path::Path, process::ExitCode};

use minotari_app_grpc::tari_rpc as grpc;
use prost::Message;
use tari_common::configuration::Network;
use tari_core::{
    consensus::BaseNodeConsensusManager,
    proof_of_work::{
        monero_randomx_difficulty,
        monero_rx::{CoinbasePrefix, CoinbasePrefixMode, CoinbaseTxPrefix, MergeMineError, MoneroPowData},
        randomx_factory::RandomXFactory,
    },
};
use tari_node_components::blocks::BlockHeader;
use tari_transaction_components::tari_proof_of_work::{Difficulty, PowAlgorithm, PowData};
use tiny_keccak::{Hasher, Keccak};

const HEIGHTS: [u64; 3] = [349_999, 350_000, 350_001];

fn mainnet() -> BaseNodeConsensusManager {
    // The domain-separated header hashes carry the network, so pin it before hashing anything.
    let _ = Network::set_current(Network::MainNet);
    BaseNodeConsensusManager::builder(Network::MainNet).build().expect("mainnet consensus manager")
}

fn templates(dir: &Path, difficulty: u64) {
    let cm = mainnet();
    let genesis = *cm.get_genesis_block().hash();
    for height in HEIGHTS {
        let constants = cm.consensus_constants(height);
        let mut header = BlockHeader::new(u16::from(constants.blockchain_version()));
        header.height = height;
        // Any parent will do: nothing here links to a chain, and the parent is covered by the merge mining hash.
        header.prev_hash = [height.to_le_bytes()[0]; 32].into();
        header.pow.pow_algo = PowAlgorithm::RandomXM;
        let merge_mining_hash = header.merge_mining_hash();
        let block = grpc::Block {
            header: Some(header.clone().into()),
            body: Some(grpc::AggregateBody::default()),
        };
        let template = grpc::GetNewBlockResult {
            block_hash: header.hash().to_vec(),
            block: Some(block),
            merge_mining_hash: merge_mining_hash.to_vec(),
            tari_unique_id: genesis.to_vec(),
            miner_data: Some(grpc::MinerData {
                algo: Some(grpc::PowAlgo { pow_algo: 0 }),
                target_difficulty: difficulty,
                reward: 1,
                total_fees: 0,
            }),
            vm_key: vec![0; 32],
        };
        let tip = grpc::TipInfoResponse {
            metadata: Some(grpc::MetaData {
                best_block_height: height - 1,
                best_block_hash: header.prev_hash.to_vec(),
                accumulated_difficulty: height.to_be_bytes().to_vec(),
                pruned_height: 0,
                timestamp: header.timestamp.as_u64(),
            }),
            initial_sync_achieved: true,
            base_node_state: 5, // LISTENING
            failed_checkpoints: false,
        };
        fs::write(dir.join(format!("template-{height}.bin")), template.encode_to_vec()).unwrap();
        fs::write(dir.join(format!("tip-{height}.bin")), tip.encode_to_vec()).unwrap();
        println!(
            "INFO template height={height} merge_mining_hash={merge_mining_hash} prefix_format={}",
            CoinbasePrefixMode::for_constants(constants)
        );
    }
}

/// First captured submission per height, in capture order.
fn captured(dir: &Path) -> Vec<(u64, BlockHeader)> {
    let mut files: Vec<_> = fs::read_dir(dir)
        .unwrap()
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.file_name().is_some_and(|n| n.to_string_lossy().starts_with("submit-")))
        .collect();
    files.sort();
    let mut out: Vec<(u64, BlockHeader)> = Vec::new();
    for path in files {
        let block = grpc::Block::decode(fs::read(&path).unwrap().as_slice()).expect("SubmitBlock request decodes");
        let header = BlockHeader::try_from(block.header.expect("submitted block has a header")).expect("header converts");
        if !out.iter().any(|(h, _)| *h == header.height) {
            out.push((header.height, header));
        }
    }
    out
}

fn with_pow_data(header: &BlockHeader, pow: &MoneroPowData) -> BlockHeader {
    let mut header = header.clone();
    header.pow.pow_data = PowData::try_from(borsh::to_vec(pow).unwrap()).unwrap();
    header
}

fn validate(dir: &Path, difficulty: u64) -> bool {
    let cm = mainnet();
    let genesis = *cm.get_genesis_block().hash();
    let factory = RandomXFactory::default();
    let captured = captured(dir);
    let mut ok = true;
    let mut row = |pass: bool, text: String| {
        println!("ROW {} {text}", if pass { "PASS" } else { "FAIL" });
        ok &= pass;
    };
    let check = |header: &BlockHeader| monero_randomx_difficulty(header, &factory, &genesis, &cm);

    for height in HEIGHTS {
        let Some((_, submitted)) = captured.iter().find(|(h, _)| *h == height) else {
            row(false, format!("{height}: P2Pool submitted a solution for this template"));
            continue;
        };
        let constants = cm.consensus_constants(height);
        let mode = CoinbasePrefixMode::for_constants(constants);
        let mainnet_min = constants.min_pow_difficulty(PowAlgorithm::RandomXM).as_u64();
        println!(
            "INFO height={height} tari_block_hash={} rules={mode} mainnet_min_randomxm_difficulty={mainnet_min} \
             test_difficulty={difficulty} pow_algo={}",
            submitted.hash(),
            submitted.pow.pow_algo
        );
        row(
            submitted.pow.pow_algo == PowAlgorithm::RandomXM,
            format!("{height}: P2Pool submitted a RandomXM (merge-mined) block"),
        );

        // P2Pool 4.18.1 always writes the prefix format; decode it that way to derive the controls.
        let raw = submitted.pow.pow_data.to_vec();
        let derived = match MoneroPowData::deserialize_with_mode(&mut raw.as_slice(), CoinbasePrefixMode::Derived) {
            Ok(p) => p,
            Err(e) => {
                row(false, format!("{height}: P2Pool's payload is in the coinbase-prefix format ({e})"));
                continue;
            },
        };
        let CoinbasePrefix::Prefix(prefix) = &derived.coinbase_prefix else { unreachable!() };
        let prefix = prefix.to_vec();

        // Same Monero block, same work: only the coinbase field is swapped for the pre-fork sponge.
        let mut sponge = Keccak::v256();
        sponge.update(&prefix);
        let legacy = MoneroPowData { coinbase_prefix: CoinbasePrefix::Legacy(sponge), ..derived.clone() };
        // Same everything, one bit of the prefix flipped (the last byte: an output view tag, still parseable).
        let mut flipped = prefix.clone();
        *flipped.last_mut().unwrap() ^= 1;
        let mutated = MoneroPowData {
            coinbase_prefix: CoinbasePrefix::Prefix(CoinbaseTxPrefix::try_from(flipped).unwrap()),
            ..derived.clone()
        };

        let accepted = |result: Result<Difficulty, MergeMineError>, what: &str| {
            match result {
                Ok(d) => {
                    let d = d.as_u64();
                    (d >= difficulty, format!("{what} ACCEPTED, achieved difficulty {d} (test target {difficulty}, mainnet min {mainnet_min})"))
                },
                Err(e) => (false, format!("{what} REJECTED: {e}")),
            }
        };
        let rejected = |result: Result<Difficulty, MergeMineError>, what: &str| match result {
            Ok(_) => (false, format!("{what} ACCEPTED, expected a rejection")),
            Err(e) => (true, format!("{what} REJECTED: {e}")),
        };

        let (p, t) = match mode {
            CoinbasePrefixMode::Legacy => rejected(check(submitted), "P2Pool 4.18.1 prefix payload"),
            CoinbasePrefixMode::Derived => accepted(check(submitted), "P2Pool 4.18.1 prefix payload"),
        };
        row(p, format!("{height} ({mode} rules): {t}"));
        let (p, t) = match mode {
            CoinbasePrefixMode::Legacy => accepted(check(&with_pow_data(submitted, &legacy)), "legacy Keccak-state payload"),
            CoinbasePrefixMode::Derived => rejected(check(&with_pow_data(submitted, &legacy)), "legacy Keccak-state payload"),
        };
        row(p, format!("{height} ({mode} rules): {t}"));
        if mode == CoinbasePrefixMode::Derived {
            let (p, t) = rejected(check(&with_pow_data(submitted, &mutated)), "mutated prefix payload");
            row(p, format!("{height} ({mode} rules): {t}"));
        }
    }
    ok
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let usage = "usage: p2pool_mm_fixture templates|validate <dir> <difficulty>";
    let (Some(cmd), Some(dir), Some(difficulty)) = (args.get(1), args.get(2), args.get(3)) else {
        eprintln!("{usage}");
        return ExitCode::from(2);
    };
    let difficulty: u64 = difficulty.parse().expect("difficulty is a u64");
    match cmd.as_str() {
        "templates" => {
            templates(Path::new(dir), difficulty);
            ExitCode::SUCCESS
        },
        "validate" if validate(Path::new(dir), difficulty) => ExitCode::SUCCESS,
        "validate" => ExitCode::FAILURE,
        _ => {
            eprintln!("{usage}");
            ExitCode::from(2)
        },
    }
}
