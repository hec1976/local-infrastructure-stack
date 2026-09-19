<?php
/**
 * Registers an autoloader function for loading classes automatically.
 *
 * This function is triggered when a class is referenced but not yet loaded.
 * It will attempt to load the class file by converting the class name to a file path
 * based on the namespace and directory structure.
 *
 * @param string $class_name The fully qualified name of the class to be loaded.
 *
 * @return void
 */
spl_autoload_register(function ($class_name) {
    // Basisverzeichnis des Projekts (Root-Verzeichnis, da der Autoloader dort liegt)
    $base_dir = __DIR__ . DIRECTORY_SEPARATOR;

    // Entferne den "ConfigManager\" Namespace-Präfix, falls vorhanden
    if (strpos($class_name, 'ConfigManager\\') === 0) {
        $class_name = substr($class_name, strlen('ConfigManager\\'));
    }

    // Ersetze Backslashes durch Systemverzeichnistrenner
    $file = $base_dir . str_replace('\\', DIRECTORY_SEPARATOR, $class_name) . '.php';

    // Überprüfe, ob die Datei existiert und lade sie
    if (file_exists($file)) {
        require_once $file;
        //echo "Class '$class_name' loaded successfully from $file<br>";  // Debug-Ausgabe
    } else {
        //echo "Class '$class_name' not found at $file<br>";  // Debugging für nicht gefundene Klassen
    }
});



?>
