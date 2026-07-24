<?php
// test/benchmark_xlib.php
// PHP json vs Python json vs lua-yar (cross-language reference)

$sample = ['a' => 1, 'b' => 'hello world', 'c' => [1, 2, 3, 4, 5], 'd' => true, 'e' => 3.14];
$json_str = json_encode($sample);
$msgpack_str = ''; // PHP msgpack not installed

function bench($name, $fn, $n) {
    // warmup
    $warmup = min($n, 1000);
    for ($i = 0; $i < $warmup; $i++) $fn();
    // measure
    $start = hrtime(true);
    for ($i = 0; $i < $n; $i++) $fn();
    $elapsed = (hrtime(true) - $start) / 1e9;
    $ops = $n / $elapsed;
    printf("  %-42s %8d ops in %6.3fs  ->  %10.0f ops/s\n", $name, $n, $elapsed, $ops);
    return $ops;
}

echo "=== PHP json benchmark ===\n";
echo "PHP version: " . PHP_VERSION . "\n";
echo "json extension: " . (function_exists('json_encode') ? 'yes' : 'no') . "\n";
echo "msgpack extension: " . (extension_loaded('msgpack') ? 'yes' : 'no') . "\n";
echo "\n";

echo "[JSON encode]\n";
bench("  php json_encode", function() use ($sample) { json_encode($sample); }, 100000);
echo "\n";

echo "[JSON decode]\n";
bench("  php json_decode", function() use ($json_str) { json_decode($json_str, true); }, 100000);
echo "\n";

if (extension_loaded('msgpack')) {
    $mp_str = msgpack_pack($sample);
    echo "[Msgpack encode]\n";
    bench("  php msgpack_pack", function() use ($sample) { msgpack_pack($sample); }, 100000);
    echo "\n";
    echo "[Msgpack decode]\n";
    bench("  php msgpack_unpack", function() use ($mp_str) { msgpack_unpack($mp_str); }, 100000);
    echo "\n";
}

echo "=== done ===\n";
