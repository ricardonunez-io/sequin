WITH current_outstanding_count AS (
  SELECT
    count(*) AS count
  FROM
    streams.outstanding_messages
  WHERE
    consumer_id = :consumer_id
),
max_new_messages AS (
  SELECT
    :max_slots -(
      SELECT
        count
      FROM
        current_outstanding_count) AS max_new_messages
),
consumer_state AS (
  SELECT
    *
  FROM
    streams.consumer_states
  WHERE
    consumer_id = :consumer_id
),
new_messages AS (
  SELECT
    *
  FROM
    streams.messages m
  WHERE
    m.stream_id = :stream_id
    AND m.seq >(
      SELECT
        message_seq_cursor
      FROM
        consumer_state)
    ORDER BY
      m.seq ASC
    LIMIT (
      SELECT
        max_new_messages
      FROM
        max_new_messages)
),
new_outstanding_messages AS (
INSERT INTO streams.outstanding_messages AS om(consumer_id, message_key, message_seq, message_stream_id, state, inserted_at, updated_at)
  SELECT
    :consumer_id,
    m.key,
    m.seq,
    m.stream_id,
    'available',
    :now,
    :now
  FROM
    new_messages m
  ON CONFLICT (consumer_id,
    message_key)
    DO UPDATE SET
      state =(
        CASE WHEN om.state = 'delivered'::streams.outstanding_message_state THEN
          'pending_redelivery'::streams.outstanding_message_state
        ELSE
          om.state
        END),
      message_seq = excluded.message_seq,
      updated_at = excluded.updated_at)
UPDATE
  streams.consumer_states
SET
  message_seq_cursor =(
    SELECT
      coalesce(max(seq), 0)
    FROM
      new_messages),
  count_pulled_into_outstanding = count_pulled_into_outstanding +(
    SELECT
      count(*)
    FROM
      new_messages)
WHERE
  consumer_id = :consumer_id
