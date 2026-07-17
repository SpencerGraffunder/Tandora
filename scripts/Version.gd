extends Node

var commit: String = ""

func _ready():
	var config := ConfigFile.new()
	var err := config.load("res://version.cfg")
	if err == OK:
		commit = config.get_value("version", "commit", "")
	else:
		commit = "?"
