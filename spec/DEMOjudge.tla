------------------------- MODULE DEMOjudge ------------------------
EXTENDS Naturals, Sequences

CONSTANTS Submission, Runner, MaxAttempts, MaxResolves, Verdict

CaseVerdict == Verdict \ {"CE"}

Severity(v) ==
    CASE v = "AC"  -> 0
      [] v = "WA"  -> 1
      [] v = "TLE" -> 2
      [] v = "MLE" -> 3
      [] v = "RE"  -> 4
      [] v = "CE"  -> 5

Worse(a, b) == IF Severity(a) >= Severity(b) THEN a ELSE b

ASSUME MaxAttempts \in Nat \ {0}
ASSUME MaxResolves \in Nat
ASSUME "CE" \in Verdict /\ CaseVerdict # {}
ASSUME \A v \in Verdict : Severity(v) \in 0..5
ASSUME "AC" \in CaseVerdict

\* The model's ceiling only. The real judge puts no bound on how often a referee
\* may resolve; MaxResolves is what keeps the state space finite.
MaxAllowance == MaxAttempts * (1 + MaxResolves)

NoLease == [submission |-> "none", attempt |-> 0, phase |-> "compiling", worst |-> "AC"]

VARIABLES
    received,
    queued,
    leased,
    lease,
    attempts,
    allowances,
    judgments,
    escalated

vars == <<received, queued, leased, lease, attempts, allowances, judgments, escalated>>

Init ==
    /\ received = {}
    /\ queued = {}
    /\ leased = {}
    /\ lease = [j \in Runner |-> NoLease]
    /\ attempts = [s \in Submission |-> 0]
    /\ allowances = [s \in Submission |-> MaxAttempts]
    /\ judgments = <<>>
    /\ escalated = {}

HasVerdict(s) == \E i \in 1..Len(judgments) : judgments[i].submission = s

SubmissionReceived(s) ==
    /\ s \notin received
    /\ received' = received \cup {s}
    /\ queued' = queued \cup {s}
    /\ UNCHANGED <<leased, lease, attempts, allowances, judgments, escalated>>

AttemptLeased(j, s) ==
    /\ lease[j] = NoLease
    /\ s \in queued
    /\ s \notin leased
    /\ attempts[s] < allowances[s]
    /\ leased' = leased \cup {s}
    /\ attempts' = [attempts EXCEPT ![s] = @ + 1]
    /\ lease' = [lease EXCEPT ![j] =
                    [submission |-> s, attempt |-> attempts[s] + 1, phase |-> "compiling", worst |-> "AC"]]
    /\ UNCHANGED <<received, queued, allowances, judgments, escalated>>

\* The case id is not in the state: Worse is the max of a total order, so
\* neither repeating nor reordering the cases can lower the worst.
TestCaseJudged(j, v) ==
    /\ lease[j] # NoLease
    /\ lease[j].phase \in {"compiling", "running"}
    /\ v \in CaseVerdict
    /\ lease' = [lease EXCEPT ![j].phase = "running", ![j].worst = Worse(@, v)]
    /\ UNCHANGED <<received, queued, leased, attempts, allowances, judgments, escalated>>

CompilationFailed(j) ==
    /\ lease[j] # NoLease
    /\ lease[j].phase = "compiling"
    /\ lease' = [lease EXCEPT ![j].phase = "ce", ![j].worst = Worse(@, "CE")]
    /\ UNCHANGED <<received, queued, leased, attempts, allowances, judgments, escalated>>

JudgmentCompleted(j, v) ==
    /\ lease[j] # NoLease
    /\ lease[j].phase # "compiling"
    /\ v = lease[j].worst
    /\ queued' = queued \ {lease[j].submission}
    /\ leased' = leased \ {lease[j].submission}
    /\ judgments' = Append(judgments, [submission |-> lease[j].submission, attempt |-> lease[j].attempt, verdict |-> v])
    /\ lease' = [lease EXCEPT ![j] = NoLease]
    /\ UNCHANGED <<received, attempts, allowances, escalated>>

Crash(j) ==
    /\ lease[j] # NoLease
    /\ lease' = [lease EXCEPT ![j] = NoLease]
    /\ UNCHANGED <<received, queued, leased, attempts, allowances, judgments, escalated>>

LeaseExpired(s) ==
    /\ s \in leased
    /\ leased' = leased \ {s}
    /\ UNCHANGED <<received, queued, lease, attempts, allowances, judgments, escalated>>

SubmissionEscalated(s) ==
    /\ s \in queued
    /\ s \notin leased
    /\ attempts[s] = allowances[s]
    /\ queued' = queued \ {s}
    /\ escalated' = escalated \cup {s}
    /\ lease' = [j \in Runner |-> IF lease[j].submission = s THEN NoLease ELSE lease[j]]
    /\ UNCHANGED <<received, leased, attempts, allowances, judgments>>

EscalationResolved(s) ==
    /\ s \in escalated
    /\ allowances[s] + MaxAttempts <= MaxAllowance
    /\ escalated' = escalated \ {s}
    /\ queued' = queued \cup {s}
    /\ allowances' = [allowances EXCEPT ![s] = @ + MaxAttempts]
    /\ UNCHANGED <<received, leased, lease, attempts, judgments>>

Next ==
    \/ \E s \in Submission : SubmissionReceived(s)
    \/ \E j \in Runner, s \in Submission : AttemptLeased(j, s)
    \/ \E j \in Runner, v \in CaseVerdict : TestCaseJudged(j, v)
    \/ \E j \in Runner : CompilationFailed(j)
    \/ \E j \in Runner, v \in Verdict : JudgmentCompleted(j, v)
    \/ \E j \in Runner : Crash(j)
    \/ \E s \in Submission : LeaseExpired(s)
    \/ \E s \in Submission : SubmissionEscalated(s)
    \/ \E s \in Submission : EscalationResolved(s)

\* LeaseExpired is fair because the model has no renewal: a Crash leaves the
\* submission in leased with no holder, so Progress needs expiry to free it.
Fairness ==
    /\ \A j \in Runner, s \in Submission : WF_vars(AttemptLeased(j, s))
    /\ \A j \in Runner : WF_vars(\E v \in CaseVerdict : TestCaseJudged(j, v))
    /\ \A j \in Runner : WF_vars(\E v \in Verdict : JudgmentCompleted(j, v))
    /\ \A s \in Submission : WF_vars(LeaseExpired(s))
    /\ \A s \in Submission : WF_vars(SubmissionEscalated(s))

Spec == Init /\ [][Next]_vars /\ Fairness

EmptyVerdicts == [x \in {} |-> x]

RECURSIVE FoldLeft(_, _)
FoldLeft(log, acc) ==
    IF log = <<>>
    THEN acc
    ELSE LET e == Head(log)
             keep == e.submission \in DOMAIN acc /\ acc[e.submission].attempt >= e.attempt
             acc2 == IF keep
                     THEN acc
                     ELSE [x \in (DOMAIN acc) \cup {e.submission} |->
                             IF x = e.submission THEN e ELSE acc[x]]
         IN FoldLeft(Tail(log), acc2)

Verdicts(log) == FoldLeft(log, EmptyVerdicts)

RECURSIVE Reverse(_)
Reverse(log) ==
    IF log = <<>> THEN <<>> ELSE Reverse(Tail(log)) \o <<Head(log)>>

Terminal(s) == HasVerdict(s) \/ s \in escalated

NoLoss == \A s \in received : s \in queued \/ Terminal(s)

Progress == \A s \in Submission : (s \in received) ~> Terminal(s)

FoldIdempotent == Verdicts(judgments \o judgments) = Verdicts(judgments)

\* Every lease stamps a new attempt, so no two entries share (submission, attempt):
\* the fold keeps the highest in any order, and reversal is a cheap witness.
FoldOrderInsensitive == Verdicts(Reverse(judgments)) = Verdicts(judgments)

===================================================================
