#!/bin/bash

set -euo pipefail
trap 'echo "Error on line $LINENO"; exit 1' ERR

usage() {
    cat <<EOF
Usage:
  $0 <n_min_pct> <n_max_pct> <n_step_pct> <n_repetitions> \
<nb_min> <nb_max> <nb_step> <nb_repetitions> <stress_repetitions>

Example:
  $0 10 80 10 5 64 256 32 5 5

Pipeline:
  1. Run hpl_n_varies.sh
  2. Select the best complete N with find_best_n.py
  3. Run hpl_nb_varies.sh using that N
  4. Select the best complete NB with find_best_nb.py
  5. Run hpl_stress.sh from S=1 to S=nproc using the selected N and NB
EOF
    exit 2
}

check_dependencies() {
    echo "==== Checking dependencies ===="

    local missing=0

    # Required for the pipeline itself and the scripts it calls.
    local required_commands=(
        awk
        bc
        collectl
        grep
        killall
        mpirun
        nproc
        pkill
        python3
        sed
        stress
    )

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "ERROR: required command not found: $cmd" >&2
            missing=1
        else
            echo "OK: $cmd -> $(command -v "$cmd")"
        fi
    done

    # Required Python standard-library modules used by find_best_n.py/find_best_nb.py.
    # They should exist in any normal Python 3 installation, but we test them anyway.
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 - <<'PY'
import argparse
import csv
import glob
import os
import re
import sys
PY
        then
            echo "ERROR: Python 3 is present but required standard modules could not be imported." >&2
            missing=1
        else
            echo "OK: Python standard modules required by selection scripts"
        fi
    fi

    # Optional: only needed by analyze_rpi_hpl.py, not by this pipeline.
    if [ -f "./analyze_rpi_hpl.py" ]; then
        if python3 - <<'PY' >/dev/null 2>&1
import matplotlib
PY
        then
            echo "OK: Python package matplotlib, needed by analyze_rpi_hpl.py"
        else
            echo "WARNING: matplotlib is not installed. The pipeline can run, but analyze_rpi_hpl.py will not generate plots." >&2
        fi
    fi


    # Temperature source check.
    # Not fatal: if no source is available, scripts will write NaN in temperature files.
    if [ -f /sys/class/thermal/thermal_zone0/temp ] || ls /sys/class/thermal/thermal_zone*/temp >/dev/null 2>&1; then
        echo "OK: Linux thermal sensor available under /sys/class/thermal"
    elif command -v vcgencmd >/dev/null 2>&1; then
        echo "OK: vcgencmd available for Raspberry Pi temperature monitoring"
    else
        echo "WARNING: no CPU temperature source found. Temperature files will contain NaN." >&2
    fi

    # Script presence check.
    local required_scripts=(
        ./hpl_n_varies.sh
        ./hpl_nb_varies.sh
        ./hpl_stress.sh
        ./find_best_n.py
        ./find_best_nb.py
    )

    for script in "${required_scripts[@]}"; do
        if [ ! -f "$script" ]; then
            echo "ERROR: required script not found: $script" >&2
            missing=1
        else
            echo "OK: found $script"
        fi
    done

    if (( missing != 0 )); then
        echo "Dependency check failed. Install the missing packages/commands and rerun." >&2
        exit 1
    fi

    echo "Dependency check completed."
}

if [ $# -ne 9 ]; then
    echo "Error: wrong number of arguments."
    usage
fi

re='^[0-9]+$'
for arg in "$@"; do
    if ! [[ $arg =~ $re ]]; then
        echo "Error: '$arg' is not a positive integer."
        usage
    fi
done

n_min_pct=$1
n_max_pct=$2
n_step_pct=$3
n_repetitions=$4

nb_min=$5
nb_max=$6
nb_step=$7
nb_repetitions=$8

stress_repetitions=$9

if (( n_repetitions <= 0 || nb_repetitions <= 0 || stress_repetitions <= 0 )); then
    echo "Error: repetitions must be > 0."
    usage
fi

check_dependencies

chmod +x ./hpl_n_varies.sh ./hpl_nb_varies.sh ./hpl_stress.sh ./find_best_n.py ./find_best_nb.py

echo "==== Stage 1/5: Varying N ===="
./hpl_n_varies.sh "$n_min_pct" "$n_max_pct" "$n_step_pct" "$n_repetitions"

echo "==== Stage 2/5: Selecting best complete N ===="
python3 ./find_best_n.py --root . --repetitions "$n_repetitions"

# shellcheck disable=SC1091
source ./best_n.env
echo "Selected BEST_N=$BEST_N"

echo "==== Stage 3/5: Varying NB with N=$BEST_N ===="
./hpl_nb_varies.sh "$BEST_N" "$nb_min" "$nb_max" "$nb_step" "$nb_repetitions"

echo "==== Stage 4/5: Selecting best complete NB ===="
python3 ./find_best_nb.py --root . --n "$BEST_N" --repetitions "$nb_repetitions"

# shellcheck disable=SC1091
source ./best_nb.env
echo "Selected BEST_NB=$BEST_NB"

MAX_STRESS_CPUS=$(nproc --all)

echo "==== Stage 5/5: Stress experiment with N=$BEST_N, NB=$BEST_NB, S=1..$MAX_STRESS_CPUS ===="
./hpl_stress.sh "$stress_repetitions" 1 "$MAX_STRESS_CPUS" "$BEST_N" "$BEST_NB"

echo "==== Pipeline completed ===="
echo "BEST_N=$BEST_N"
echo "BEST_NB=$BEST_NB"
echo "MAX_STRESS_CPUS=$MAX_STRESS_CPUS"
