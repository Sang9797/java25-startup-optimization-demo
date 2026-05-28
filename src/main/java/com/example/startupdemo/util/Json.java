package com.example.startupdemo.util;

import java.util.Collection;
import java.util.Iterator;
import java.util.Map;

public final class Json {
    private Json() {
    }

    public static String object(Map<String, ?> values) {
        StringBuilder builder = new StringBuilder("{");
        Iterator<? extends Map.Entry<String, ?>> iterator = values.entrySet().iterator();
        while (iterator.hasNext()) {
            Map.Entry<String, ?> entry = iterator.next();
            builder.append(quote(entry.getKey())).append(':').append(value(entry.getValue()));
            if (iterator.hasNext()) {
                builder.append(',');
            }
        }
        return builder.append('}').toString();
    }

    private static String value(Object value) {
        return switch (value) {
            case null -> "null";
            case String string -> quote(string);
            case Number number -> number.toString();
            case Boolean bool -> bool.toString();
            case Map<?, ?> map -> mapValue(map);
            case Collection<?> collection -> collectionValue(collection);
            default -> quote(value.toString());
        };
    }

    private static String mapValue(Map<?, ?> map) {
        StringBuilder builder = new StringBuilder("{");
        Iterator<? extends Map.Entry<?, ?>> iterator = map.entrySet().iterator();
        while (iterator.hasNext()) {
            Map.Entry<?, ?> entry = iterator.next();
            builder.append(quote(String.valueOf(entry.getKey()))).append(':').append(value(entry.getValue()));
            if (iterator.hasNext()) {
                builder.append(',');
            }
        }
        return builder.append('}').toString();
    }

    private static String collectionValue(Collection<?> collection) {
        StringBuilder builder = new StringBuilder("[");
        Iterator<?> iterator = collection.iterator();
        while (iterator.hasNext()) {
            builder.append(value(iterator.next()));
            if (iterator.hasNext()) {
                builder.append(',');
            }
        }
        return builder.append(']').toString();
    }

    private static String quote(String value) {
        return '"' + value
                .replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\n", "\\n")
                .replace("\r", "\\r")
                .replace("\t", "\\t") + '"';
    }
}
