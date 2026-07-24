<?php

$client = new Yar_Client("http://localhost/test/server.php");

$client->SetOpt(YAR_OPT_PACKAGER, "json");
$client->SetOpt(YAR_OPT_PROXY, "127.0.0.1:8888");
$client->SetOpt(YAR_OPT_HEADER,["cache"=>"fangle"]);
/* call remote service */

$obj = new stdClass();
$obj->id = 1;
$result = $client->hello(1);


