using HOPE

function main(args)
    if length(args) != 2
        println("Usage: julia --project=. tools/repo_utils/audit_holistic_case_pair.jl <GTEP_case> <PCM_case>")
        return 1
    end

    gtep_case, pcm_case = args
    try
        println("Auditing holistic pair:")
        println("  GTEP: ", gtep_case)
        println("  PCM : ", pcm_case)

        report = HOPE.validate_holistic_handoff_contract(gtep_case, pcm_case)
        println()
        for row in eachrow(report["checks"])
            status = row.Severity == "warning" ? "WARN" : (row.Passed ? "PASS" : "FAIL")
            println("  [", status, "] ", row.Check, ": ", row.Evidence)
        end

        println("\nHolistic handoff contract passed.")
        return 0
    catch err
        println(err)
        return 2
    end
end

exit(main(ARGS))
