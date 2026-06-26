# HPL Raspberry Pi Experiment Pipeline Scripts

## Why are `find_best_n.py` and `find_best_nb.py` written in Python?

They are written in Python because they must parse many HPL `.out` files, verify that all expected repetitions exist, extract GFLOPS values, compute means, write summary CSV files, and generate shell-compatible `.env` files.

This is possible in shell, but it would be more fragile because it would require complex combinations of `grep`, `sed`, `awk`, filename parsing, missing-file handling, floating-point arithmetic, and CSV writing.

The Python scripts use only the Python standard library, so they do not introduce an extra package dependency beyond `python3`.

## Scripts

### `hpl_n_varies.sh`

Vary HPL `N` based on available RAM percentage.

```bash
./hpl_n_varies.sh <min_percentage> <max_percentage> <step_percentage> <repetitions>
```

Example:

```bash
./hpl_n_varies.sh 10 80 10 5
```

### `find_best_n.py`

Find the `N` with the highest mean GFLOPS among configurations that completed all expected repetitions.

```bash
python3 find_best_n.py --root . --repetitions 5
```

Outputs:

- `n_performance_summary.csv`
- `best_n.env`

### `hpl_nb_varies.sh`

Vary HPL `NB` for a fixed `N`.

```bash
./hpl_nb_varies.sh <N> <min_NB> <max_NB> <step_NB> <repetitions>
```

Example:

```bash
./hpl_nb_varies.sh 15848 64 256 32 5
```

### `find_best_nb.py`

Find the `NB` with the highest mean GFLOPS among configurations that completed all expected repetitions.

```bash
python3 find_best_nb.py --root . --n 15848 --repetitions 5
```

Outputs:

- `nb_performance_summary.csv`
- `best_nb.env`

### `hpl_stress.sh`

Run HPL under CPU stress for fixed `N` and `NB`.

```bash
./hpl_stress.sh <repetitions> <min_stress_cpus> <max_stress_cpus> <N> <NB>
```

Example:

```bash
./hpl_stress.sh 5 1 4 15848 128
```

### `hpl_experiment_pipeline.sh`

Run the full experiment pipeline:

1. Vary `N`.
2. Select the best complete `N`.
3. Vary `NB` using the selected `N`.
4. Select the best complete `NB`.
5. Run stress experiments from `S=1` to `S=nproc`.

```bash
./hpl_experiment_pipeline.sh <n_min_pct> <n_max_pct> <n_step_pct> <n_repetitions> \
<nb_min> <nb_max> <nb_step> <nb_repetitions> <stress_repetitions>
```

Example:

```bash
./hpl_experiment_pipeline.sh 10 80 10 5 64 256 32 5 5
```

## Dependency check

`hpl_experiment_pipeline.sh` checks the commands needed by the full pipeline:

- `awk`
- `bc`
- `collectl`
- `grep`
- `killall`
- `mpirun`
- `nproc`
- `pkill`
- `python3`
- `sed`
- `stress`

It also verifies that the Python standard modules used by the selection scripts are available.

If `analyze_rpi_hpl.py` is present, it also checks whether `matplotlib` is installed. Missing `matplotlib` is reported as a warning because it is needed only for post-analysis plots, not for the experiment pipeline itself.

## Recommended nohup execution

From the directory containing `xhpl`, `HPL.dat`, and these scripts:

```bash
chmod +x *.sh *.py

nohup ./hpl_experiment_pipeline.sh 10 80 10 5 64 256 32 5 5 \
  > hpl_pipeline.log 2>&1 < /dev/null &

echo $! > hpl_pipeline.pid
```

After reconnecting:

```bash
cat hpl_pipeline.pid
ps -p "$(cat hpl_pipeline.pid)" -o pid,ppid,stat,etime,cmd
tail -f hpl_pipeline.log
```

## Important notes

- These scripts assume they are executed inside the directory containing `xhpl`.
- They also assume that `HPL.dat` is present in the same directory.
- Do not run two full pipelines in the same directory at the same time.
- Do not run two `hpl_stress.sh` campaigns simultaneously with the same user, because the script intentionally kills all visible `stress` processes before and after each stress run.


## Temperature monitoring

The execution scripts generate a temperature log for each repetition:

```text
temperature_rep0.csv
temperature_rep1.csv
...
```

Each file uses this format:

```text
timestamp;phase;temperature_celsius;throttled
2026-06-26 17:10:01;before;48.125;0x0
2026-06-26 17:10:06;during;51.250;0x0
2026-06-26 17:12:32;after;58.000;0x0
```

The `phase` column can be:

- `before`: the 5-second pre-HPL monitoring window.
- `during`: the HPL execution window.
- `after`: the 5-second post-HPL monitoring window.

Temperature source priority:

1. `/sys/class/thermal/thermal_zone0/temp`
2. any available `/sys/class/thermal/thermal_zone*/temp`
3. `vcgencmd measure_temp`
4. `NaN` if no source is available

The `throttled` column is filled with `vcgencmd get_throttled` when available, otherwise `NaN`.

The sampling interval is controlled by `TEMP_INTERVAL`, defaulting to 1 second:

```bash
TEMP_INTERVAL=2 ./hpl_n_varies.sh 10 80 10 5
```

With `nohup`:

```bash
TEMP_INTERVAL=2 nohup ./hpl_experiment_pipeline.sh 10 80 10 5 64 256 32 5 5 \
  > hpl_pipeline.log 2>&1 < /dev/null &
```

## CPU count for stress experiments

The stress stage uses `nproc --all` instead of plain `nproc` to avoid inconsistencies when thread-related environment variables or affinity restrictions make `nproc` report only the currently available processing units. This prevents the pipeline from selecting a stress range such as `1..10` and then having `hpl_stress.sh` reject it because plain `nproc` reports `1` inside the script.
