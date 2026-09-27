//! Bounded in-memory diagnostics, not an immutable audit log or filesystem logs.
//! Explicit clearing preserves the listener identity, monotonic sequence and a
//! redacted clear marker. Requests finishing later are recorded normally.
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::VecDeque;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ClearRequest {
    pub instance_id: String,
    pub expected_generation: u64,
    pub through_sequence: u64,
}
impl ClearRequest {
    pub fn parse(body: Option<Value>) -> Result<Self, &'static str> {
        let input: Self =
            serde_json::from_value(body.ok_or("invalid_body")?).map_err(|_| "invalid_body")?;
        if uuid::Uuid::parse_str(&input.instance_id).is_err() || input.expected_generation == 0 {
            return Err("invalid_body");
        }
        Ok(input)
    }
}

pub(super) struct History {
    entries: VecDeque<Value>,
    sequence: u64,
    generation: u64,
    cleared_through: u64,
}
impl Default for History {
    fn default() -> Self {
        Self {
            entries: VecDeque::new(),
            sequence: 0,
            generation: 1,
            cleared_through: 0,
        }
    }
}
impl History {
    pub fn len(&self) -> usize {
        self.entries.len()
    }
    pub fn records(&self, instance: &str, after: u64, limit: usize) -> Value {
        let entries: Vec<_> = self
            .entries
            .iter()
            .filter(|r| r["sequence"].as_u64().unwrap() > after)
            .take(limit)
            .cloned()
            .collect();
        let next = entries
            .last()
            .and_then(|r| r["sequence"].as_u64())
            .unwrap_or(after);
        json!({"instanceId":instance,"generation":self.generation,"clearedThrough":self.cleared_through,
            "entries":entries,"next":next,"oldest":self.entries.front().and_then(|r|r["sequence"].as_u64()),"latest":self.sequence})
    }
    pub fn record(&mut self, mut value: Value, timestamp: u64) {
        self.sequence = self.sequence.saturating_add(1);
        value["sequence"] = json!(self.sequence);
        value["timestamp"] = json!(timestamp);
        if self.entries.len() >= 200 {
            self.entries.pop_front();
        }
        self.entries.push_back(value);
    }
    pub fn clear(
        &mut self,
        instance: &str,
        input: &ClearRequest,
        request_id: &str,
        principal: &str,
        timestamp: u64,
    ) -> Result<Value, &'static str> {
        if input.instance_id != instance || input.expected_generation != self.generation {
            return Err("history_changed");
        }
        if input.through_sequence > self.sequence {
            return Err("invalid_watermark");
        }
        let next_generation = self.generation.checked_add(1).ok_or("history_changed")?;
        let before = self.entries.len();
        self.entries
            .retain(|entry| entry["sequence"].as_u64().unwrap() > input.through_sequence);
        let removed = before - self.entries.len();
        self.generation = next_generation;
        self.cleared_through = self.cleared_through.max(input.through_sequence);
        self.record(json!({"requestId":request_id,"operation":"clearRequests","method":"POST","principal":principal,
            "status":200,"outcome":"historyCleared","error":null,"reason":null,"bytes":0,"elapsedMs":0,
            "historyGeneration":self.generation,"clearedThrough":input.through_sequence,"removed":removed}), timestamp);
        Ok(
            json!({"instanceId":instance,"generation":self.generation,"clearedThrough":self.cleared_through,
            "throughSequence":input.through_sequence,"removed":removed,"latest":self.sequence}),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const INSTANCE: &str = "11111111-1111-4111-8111-111111111111";
    fn input(generation: u64, through: u64) -> ClearRequest {
        ClearRequest {
            instance_id: INSTANCE.into(),
            expected_generation: generation,
            through_sequence: through,
        }
    }
    #[test]
    fn clear_preserves_instance_monotonic_sequence_and_late_completion() {
        let mut history = History::default();
        for n in 0..5 {
            history.record(json!({"requestId":n}), 42);
        }
        let result = history
            .clear(INSTANCE, &input(1, 3), "clear-id", "key-id", 43)
            .unwrap();
        assert_eq!(result["removed"], 3);
        assert_eq!(result["generation"], 2);
        assert_eq!(result["latest"], 6);
        history.record(json!({"requestId":"previously-active"}), 44);
        let page = history.records(INSTANCE, 0, 100);
        assert_eq!(page["instanceId"], INSTANCE);
        assert_eq!(page["latest"], 7);
        assert_eq!(page["clearedThrough"], 3);
        assert_eq!(
            page["entries"]
                .as_array()
                .unwrap()
                .iter()
                .map(|r| r["sequence"].as_u64().unwrap())
                .collect::<Vec<_>>(),
            vec![4, 5, 6, 7]
        );
        assert_eq!(page["entries"][2]["outcome"], "historyCleared");
        assert_eq!(page["entries"][3]["requestId"], "previously-active");
    }
    #[test]
    fn stale_or_future_clear_is_atomic_and_never_retargets_new_history() {
        let mut history = History::default();
        history.record(json!({}), 1);
        let before = history.records(INSTANCE, 0, 100);
        assert_eq!(
            history.clear("other", &input(1, 1), "r", "k", 2),
            Err("history_changed")
        );
        assert_eq!(
            history.clear(INSTANCE, &input(1, 2), "r", "k", 2),
            Err("invalid_watermark")
        );
        assert_eq!(history.records(INSTANCE, 0, 100), before);
        history.clear(INSTANCE, &input(1, 1), "r", "k", 2).unwrap();
        let saved = history.records(INSTANCE, 0, 100);
        assert_eq!(
            history.clear(INSTANCE, &input(1, 1), "r", "k", 2),
            Err("history_changed")
        );
        assert_eq!(history.records(INSTANCE, 0, 100), saved);
    }
    #[test]
    fn ring_budget_stays_bounded_and_clear_marker_is_not_empty_success() {
        let mut history = History::default();
        for _ in 0..500 {
            history.record(json!({}), 1);
        }
        assert_eq!(history.len(), 200);
        assert_eq!(
            history
                .clear(INSTANCE, &input(1, 500), "r", "k", 2)
                .unwrap()["removed"],
            200
        );
        let page = history.records(INSTANCE, 500, 100);
        assert_eq!(page["entries"].as_array().unwrap().len(), 1);
        assert_eq!(page["entries"][0]["sequence"], 501);
        assert_eq!(page["entries"][0]["operation"], "clearRequests");
    }
    #[test]
    fn body_rejects_unknown_fields_and_wrong_types() {
        for body in [
            None,
            Some(json!({})),
            Some(
                json!({"instanceId":INSTANCE,"expectedGeneration":1,"throughSequence":0,"token":"secret"}),
            ),
            Some(json!({"instanceId":INSTANCE,"expectedGeneration":"1","throughSequence":0})),
            Some(json!({"instanceId":INSTANCE,"expectedGeneration":0,"throughSequence":0})),
        ] {
            assert!(ClearRequest::parse(body).is_err());
        }
    }
}
