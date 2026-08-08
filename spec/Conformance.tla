------------------------ MODULE Conformance ------------------------
\* The state mapping: L is the append-only log, one record per line of
\* event.line, and each operator names the DEMOjudge variable it refines.
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Submission, Runner, MaxAttempts, MaxResolves, Verdict

\* Only constant operators are taken; the state variables play no part here.
D == INSTANCE DEMOjudge WITH
    received <- {}, queued <- {}, leased <- {}, lease <- {},
    attempts <- {}, allowances <- {}, judgments <- <<>>, escalated <- {}

NoLease == D!NoLease

Line == [seq : Nat, type : STRING, submission : STRING,
         attempt : Nat, five : STRING, six : STRING]

Range(q) == { q[i] : i \in 1..Len(q) }

MaxOf(S) == CHOOSE m \in S : \A x \in S : x <= m

Lines(L, s) == SelectSeq(L, LAMBDA e : e.submission = s)

Received(L) == { e.submission :
                   e \in { f \in Range(L) : f.type = "SubmissionReceived" } }

\* The lines that settle where a submission waits.
Settling == {"SubmissionReceived", "EscalationResolved",
             "JudgmentCompleted", "SubmissionEscalated"}

LastSettling(L, s) ==
    LET q == SelectSeq(Lines(L, s), LAMBDA e : e.type \in Settling)
    IN q[Len(q)]

Queued(L) == { s \in Received(L) :
                 LastSettling(L, s).type \in {"SubmissionReceived",
                                              "EscalationResolved"} }

Escalated(L) == { s \in Received(L) :
                    LastSettling(L, s).type = "SubmissionEscalated" }

Judging == {"AttemptLeased", "CompilationFailed",
            "TestCaseJudged", "JudgmentCompleted"}

Attempts(L) == [ s \in Received(L) |->
                   MaxOf({ e.attempt :
                             e \in { f \in Range(Lines(L, s)) :
                                       f.type \in Judging } } \cup {0}) ]

Allowances(L) == [ s \in Received(L) |->
                     MaxAttempts *
                       (1 + Cardinality({ e \in Range(Lines(L, s)) :
                                            e.type = "EscalationResolved" })) ]

Open == {"AttemptLeased", "TestCaseJudged", "CompilationFailed"}
Shut == {"LeaseExpired", "JudgmentCompleted", "SubmissionEscalated"}

Worst(L, s, a) ==
    LET judged == { e.six : e \in { f \in Range(Lines(L, s)) :
                                      f.type = "TestCaseJudged"
                                        /\ f.attempt = a } }
        ce == IF \E e \in Range(Lines(L, s)) :
                     e.type = "CompilationFailed" /\ e.attempt = a
              THEN {"CE"} ELSE {}
        pool == judged \cup ce \cup {"AC"}
    IN CHOOSE v \in pool : \A w \in pool : D!Severity(w) <= D!Severity(v)

Held(L, s) ==
    LET opens == { i \in 1..Len(L) :
                     L[i].submission = s /\ L[i].type \in Open }
    IN IF opens = {} THEN NoLease
       ELSE LET i == MaxOf(opens)
            IN IF \E k \in (i + 1)..Len(L) :
                     L[k].submission = s /\ L[k].type \in Shut
               THEN NoLease
               ELSE [submission |-> s,
                     attempt |-> L[i].attempt,
                     phase |-> CASE L[i].type = "AttemptLeased" -> "compiling"
                                 [] L[i].type = "CompilationFailed" -> "ce"
                                 [] OTHER -> "running",
                     worst |-> Worst(L, s, L[i].attempt)]

Leased(L) == { s \in Received(L) : Held(L, s) # NoLease }

\* The holder is the runner column of the lease line that opened the held attempt.
Holder(L, s) ==
    LET taken == { e \in Range(Lines(L, s)) :
                     e.type = "AttemptLeased"
                       /\ e.attempt = Held(L, s).attempt }
    IN (CHOOSE e \in taken : TRUE).five

Lease(L) == [ j \in Runner |->
                IF \E s \in Leased(L) : Holder(L, s) = j
                THEN Held(L, CHOOSE s \in Leased(L) : Holder(L, s) = j)
                ELSE NoLease ]

Judgments(L) ==
    LET q == SelectSeq(L, LAMBDA e : e.type = "JudgmentCompleted")
    IN [ i \in 1..Len(q) |-> [submission |-> q[i].submission,
                              attempt |-> q[i].attempt,
                              verdict |-> q[i].five] ]

-------------------------------------------------------------------

Ln(n, t, s, a, f5, f6) == [seq |-> n, type |-> t, submission |-> s,
                           attempt |-> a, five |-> f5, six |-> f6]

\* One judged, one compile-failed, one expired twice into escalation and back.
Example == <<
    Ln(1, "SubmissionReceived", "s1", 0, "10", "c"),
    Ln(2, "AttemptLeased", "s1", 1, "j1", "25"),
    Ln(3, "TestCaseJudged", "s1", 1, "c1", "WA"),
    Ln(4, "JudgmentCompleted", "s1", 1, "WA", "-"),
    Ln(5, "SubmissionReceived", "s2", 0, "11", "c"),
    Ln(6, "AttemptLeased", "s2", 1, "j1", "26"),
    Ln(7, "LeaseExpired", "s2", 1, "j1", "-"),
    Ln(8, "AttemptLeased", "s2", 2, "j1", "40"),
    Ln(9, "CompilationFailed", "s2", 2, "compile_error", "-"),
    Ln(10, "JudgmentCompleted", "s2", 2, "CE", "-"),
    Ln(11, "SubmissionReceived", "s3", 0, "12", "c"),
    Ln(12, "AttemptLeased", "s3", 1, "j1", "50"),
    Ln(13, "LeaseExpired", "s3", 1, "-", "-"),
    Ln(14, "AttemptLeased", "s3", 2, "j1", "60"),
    Ln(15, "LeaseExpired", "s3", 2, "j1", "-"),
    Ln(16, "SubmissionEscalated", "s3", 2, "max_attempts", "-"),
    Ln(17, "EscalationResolved", "s3", 0, "referee", "-")
>>

ASSUME \A e \in Range(Example) : e \in Line
ASSUME Received(Example) = {"s1", "s2", "s3"}
ASSUME Queued(Example) = {"s3"}
ASSUME Escalated(Example) = {}
ASSUME Escalated(SubSeq(Example, 1, 16)) = {"s3"}
ASSUME Attempts(Example)["s1"] = 1 /\ Attempts(Example)["s2"] = 2
         /\ Attempts(Example)["s3"] = 2
ASSUME Allowances(Example)["s1"] = MaxAttempts
         /\ Allowances(Example)["s3"] = 2 * MaxAttempts
ASSUME Worst(Example, "s1", 1) = "WA"
ASSUME Held(Example, "s1") = NoLease
ASSUME Held(SubSeq(Example, 1, 9), "s2") =
         [submission |-> "s2", attempt |-> 2, phase |-> "ce", worst |-> "CE"]
ASSUME Leased(Example) = {}
ASSUME Leased(SubSeq(Example, 1, 9)) = {"s2"}
ASSUME Lease(SubSeq(Example, 1, 9))["j1"] =
         Held(SubSeq(Example, 1, 9), "s2")
ASSUME Lease(Example) = [j \in Runner |-> NoLease]
ASSUME Judgments(Example) =
         << [submission |-> "s1", attempt |-> 1, verdict |-> "WA"],
            [submission |-> "s2", attempt |-> 2, verdict |-> "CE"] >>

VARIABLE checked

Init == checked = TRUE

Next == UNCHANGED checked

===================================================================
